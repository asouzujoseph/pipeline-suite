#!/usr/bin/env perl
### rsem.pl ########################################################################################
use AutoLoader 'AUTOLOAD';
use strict;
use warnings;
use Carp;
use Getopt::Std;
use Getopt::Long;
use POSIX qw(strftime);
use File::Basename;
use File::Path qw(make_path);
use YAML qw(LoadFile);

my $cwd = dirname($0);
require "$cwd/shared/utilities.pl";

####################################################################################################
# version       author		comment
# 1.0		sprokopec       script to run RSEM on STAR-aligned RNASeq data

### USAGE ##########################################################################################
# rsem.pl -t tool_config.yaml -c data_config.yaml
#
# where:
# 	- tool_config.yaml contains tool versions and parameters, output directory,
# 	reference information, etc.
# 	- data_config.yaml contains sample information (YAML file containing paths to STAR-aligned
# 	BAMs (post merge/markdup), generated by create_final_yaml.pl)

### DEFINE SUBROUTINES #############################################################################
# format command to run RSEM
sub get_rsem_command {
	my %args = (
		input		=> undef,
		output_stem	=> undef,
		ref_dir		=> undef,
		tmp_dir		=> undef,
		strand		=> undef,
		@_
		);

	my $rsem_command = join(' ',
		'rsem-calculate-expression',
		'--paired-end --bam --estimate-rspd --output-genome-bam',
		'--temporary-folder', $args{tmp_dir},
		'-p 8'
		);

	if (defined($args{strand})) {
		$rsem_command = join(' ',
			$rsem_command,
			'--strandedness', $args{strand}
			);
		}

	$rsem_command = join(' ',
		$rsem_command,
		$args{input},
		$args{ref_dir},
		$args{output_stem}
		);

	return($rsem_command);
	}

### MAIN ###########################################################################################
sub main{
	my %args = (
		tool_config => undef,
		data_config => undef,
		@_
		);

	my $tool_config = $args{tool_config};
	my $data_config = $args{data_config};

	### PREAMBLE ######################################################################################

	# load tool config
	my $tool_data_orig = LoadFile($tool_config);
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'rsem');
	$tool_data->{date} = strftime "%F", localtime;
	
	# start logging
	print "---\n";
	print "Running RNASeq RSEM pipeline.\n";
	print "\n  Tool config used: $tool_config";
	print "\n    Reference used: $tool_data->{reference}";
	print "\n    Output directory: $tool_data->{output_dir}";
        print "\n    Strandedness: $tool_data->{strandedness}";
	print "\n  Sample config used: $data_config";
	print "\n---";

	# set tools and versions
	my $rsem = $tool_data->{tool} . '/' . $tool_data->{tool_version};

	# check for resume and confirm output directories
	my ($resume, $output_directory, $log_directory) = set_output_path(tool_data => $tool_data);

	my (@files, $run_count, $outfile, $touch_exit_status);
	if ('N' eq $tool_data->{dry_run}) {
		# initiate a file to hold job metrics (ensures that an existing file isn't overwritten by concurrent jobs)
		opendir(LOGFILES, $log_directory) or die "Cannot open $log_directory";
		@files = grep { /slurm_job_metrics/ } readdir(LOGFILES);
		$run_count = scalar(@files) + 1;
		closedir(LOGFILES);

		$outfile = $log_directory . '/slurm_job_metrics_' . $run_count . '.out';
		$touch_exit_status = system("touch $outfile");
		if (0 != $touch_exit_status) { Carp::croak("Cannot touch file $outfile"); }
		}

	### RUN ###########################################################################################
	# get sample data
	my $smp_data = LoadFile($data_config);

	my ($run_script, $run_id, $raw_link, $final_link);
	my @all_jobs;

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print "\nInitiating process for PATIENT: $patient\n";

		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};

		my @samples = @tumour_ids;
		if (scalar(@normal_ids) > 0) { push @samples, @normal_ids; }

		my (@patient_jobs, @final_outputs);
		my $cleanup_cmd = '';

		foreach my $sample (@samples) {

			print "  SAMPLE: $sample\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			my $link_directory = join('/', $sample_directory, 'bam_links');
			unless(-e $link_directory) { make_path($link_directory); }

			my $tmp_directory = join('/', $sample_directory, 'TEMP');
			unless(-e $tmp_directory) { make_path($tmp_directory); }
			$cleanup_cmd .= "\nrm -rf $tmp_directory";

			my $type;
			if ($sample =~ m/BC|SK|A/) { $type = 'normal'; } else { $type = 'tumour'; }

			# because smp_data points to STAR-aligned, picard merged/markdup BAMs,
			# we need to first, get the parent directory
			my $data_dir = $smp_data->{$patient}->{$type}->{$sample};
			my @parts = split /\//, $data_dir;
			$data_dir =~ s/$parts[-1]//;
			$data_dir =~ s/\/$//;

			# now direct it to the specific sample of interest
			my $aligned_bam = join('/', $data_dir, $sample, 'Aligned.toTranscriptome.out.bam');

			print "    STAR aligned BAM: $aligned_bam\n\n";
			
			# create a symlink for the bam
			my @tmp = split /\//, $aligned_bam;
			$raw_link = join('/', $link_directory, $tmp[-1]);
			symlink($aligned_bam, $raw_link);

			# reset run_id for this sample
			$run_id = '';
			my @smp_jobs;

			## RUN RSEM
			my $rsem_cmd = "cd $sample_directory;\n";
			$rsem_cmd .= get_rsem_command( 
				input		=> $aligned_bam,
				output_stem	=> $sample,
				ref_dir		=> $tool_data->{reference},
				tmp_dir		=> $tmp_directory,
				strand		=> $tool_data->{strandedness}
				);

			my $genes_file = join('/', $sample_directory, $sample . '.genes.results');
			my $isoforms_file = join('/', $sample_directory, $sample . '.isoforms.results');

			# add files to cleanup
			$cleanup_cmd .= "\nrm " . join('/', $sample_directory, '*.bam');

			# check if this should be run
			if ( ('N' eq $resume) || ('Y' eq missing_file($genes_file)) ) {

				# record command (in log directory) and then run job
				print "Submitting job for RSEM...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_RSEM_' . $sample,
					cmd	=> $rsem_cmd,
					modules	=> [$rsem],
					dependencies	=> $run_id,
					max_time	=> $tool_data->{parameters}->{rsem}->{time},
					mem		=> $tool_data->{parameters}->{rsem}->{mem},
					hpc_driver	=> $tool_data->{HPC_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_RSEM_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $tool_data->{HPC_driver},
					dry_run		=> $tool_data->{dry_run}
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;

				# IF THIS STEP IS SUCCESSFULLY RUN,	
				# create a symlink for the final output in the TOP directory
				my @final = split /\//, $genes_file;
				my $link_genes = $final[-1];
				my $link_isoforms = $final[-1];
				$link_isoforms =~ s/genes/isoforms/;

				my $links_cmd = join("\n",
					"cd $patient_directory",
					"ln -s $genes_file .",
					"ln -s $isoforms_file .",
					"cd $tool_data->{output_dir}"
					);

				if (-l $link_genes) {
					unlink $link_genes or die "Failed to remove previous symlink: $link_genes;\n";
					}
				if (-l $link_isoforms) {
					unlink $link_isoforms or die "Failed to remove previous symlink: $link_isoforms;";
					}

				$links_cmd .= "\n";
				$links_cmd .= join("\n",
					"ln -s $genes_file .",
					"ln -s $isoforms_file ."
					);

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'create_symlink_' . $sample,
					cmd	=> $links_cmd,
					dependencies	=> $run_id,
					mem		=> '256M',
					max_time	=> '00:05:00',
					hpc_driver	=> $tool_data->{HPC_driver}					
					);

				$run_id = submit_job(
					jobname		=> 'create_symlinks_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $tool_data->{HPC_driver},
					dry_run		=> $tool_data->{dry_run}
					);

				push @patient_jobs, $run_id;
				}
			else {
				print "Skipping rsem-calculate-expression because this has already been completed!\n";
				}

			push @final_outputs, $genes_file;
			push @final_outputs, $isoforms_file;
			}

		# run cleanup, once per patient
		if ('Y' eq $tool_data->{del_intermediate}) {

			print "Submitting job to clean up temporary/intermediate files...\n";

			# make sure final output exists before removing intermediate files!
			$cleanup_cmd = join("\n",
				"if [ -s " . join(" ] && [ -s ", @final_outputs) . " ]; then",
				$cleanup_cmd,
				"else",
				'echo "One or more FINAL OUTPUT FILES is missing; not removing intermediates"',
				"fi"
				);

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_cleanup_' . $patient,
				cmd	=> $cleanup_cmd,
				dependencies	=> join(',', @patient_jobs),
				max_time	=> '00:05:00',
				mem		=> '256M',
				hpc_driver	=> $tool_data->{HPC_driver}
				);

			$run_id = submit_job(
				jobname		=> 'run_cleanup_' . $patient,
				shell_command	=> $run_script,
				hpc_driver	=> $tool_data->{HPC_driver},
				dry_run		=> $tool_data->{dry_run}
				);
			}

		print "\nFINAL OUTPUT:\n" . join("\n  ", @final_outputs) . "\n";
		print "---\n";
		}

	# collect job metrics if any were run
	if ('N' eq $tool_data->{dry_run}) {

		# collect job stats
		my $collect_metrics = collect_job_stats(
			job_ids	=> join(',', @all_jobs),
			outfile	=> $outfile
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'output_job_metrics_' . $run_count,
			cmd	=> $collect_metrics,
			dependencies	=> join(',', @all_jobs),
			max_time	=> '0:05:00',
			mem		=> '256M',
			hpc_driver	=> $tool_data->{HPC_driver}
			);

		$run_id = submit_job(
			jobname		=> 'output_job_metrics',
			shell_command	=> $run_script,
			hpc_driver	=> $tool_data->{HPC_driver},
			dry_run		=> $tool_data->{dry_run}
			);
		}

	# final job to output a BAM config for downstream stuff
	if ('Y' eq $tool_data->{create_output_yaml}) {

		print "Creating config yaml for output .results files...\n";

		my $output_yaml_cmd = join(' ',
			"perl $cwd/shared/create_final_yaml.pl",
			'-d', $output_directory,
			'-o', $output_directory . '/rsem_genes_config.yaml',
			'-p', 'genes.results$'
			);

		$output_yaml_cmd .= ";\n" . join(' ',
			"perl $cwd/shared/create_final_yaml.pl",
			'-d', $output_directory,
			'-o', $output_directory . '/rsem_isoforms_config.yaml',
			'-p', 'isoforms.results$'
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'output_final_yaml',
			cmd	=> $output_yaml_cmd,
			modules	=> ['perl'],
			dependencies	=> join(',', @all_jobs),
			max_time	=> '00:10:00',
			mem		=> '1G',
			hpc_driver	=> $tool_data->{HPC_driver}
			);

		$run_id = submit_job(
			jobname		=> 'output_final_yaml',
			shell_command	=> $run_script,
			hpc_driver	=> $tool_data->{HPC_driver},
			dry_run		=> $tool_data->{dry_run}
			);

		} else {
			print "Not creating output config yaml as requested...\n";
		}

	# finish up
	print "\nProgramming terminated successfully.\n\n";

	}

### GETOPTS AND DEFAULT VALUES #####################################################################
# declare variables
my $tool_config;
my $data_config;

# get command line arguments
GetOptions(
	't|tool=s'	=> \$tool_config,
	'c|config=s'	=> \$data_config
	);

# quick error checks to confirm valid arguments
if (!defined($tool_config)) { die("No tool config file defined; please provide -t | --tool (ie, tool_config.yaml)"); }
if (!defined($data_config)) { die("No data config file defined; please provide -c | --config (ie, sample_config.yaml)"); }

# run it!
main(tool_config => $tool_config, data_config => $data_config);
