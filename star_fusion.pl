#!/usr/bin/env perl
### star_fusion.pl #################################################################################
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
# version       author	  	comment
# 1.0		sprokopec       script to run STAR-fusion on RNASeq data aligned with STAR

### USAGE ##########################################################################################
# star_fusion.pl -t tool_config.yaml -c data_config.yaml
#
# where:
#	- tool_config.yaml contains tool versions and parameters, output directory,
#	reference information, etc.
#	- data_config.yaml contains sample information (YAML file containing paths to STAR-aligned
#	BAMs (post merge/markdup), generated by create_final_yaml.pl)

### SUBROUTINES ####################################################################################
# format command to run STAR-Fusion
sub get_star_fusion_command {
	my %args = (
		fusion_call	=> undef,
		reference	=> undef,
		input		=> undef,
		output_dir	=> undef,
		tmp_dir		=> undef,
		fusion_inspect	=> undef,
		r1		=> undef,
		r2		=> undef,
		@_
		);

	if (!defined($args{fusion_call})) {
		$args{fusion_call} = 'STAR-Fusion';
		}

	my $star_command = join(' ',
		$args{fusion_call},
		'--genome_lib_dir', $args{reference},
		'--chimeric_junction', $args{input}, # Chimeric.out.junction
		'--output_dir', $args{output_dir},
		'--CPU 4',
		'--tmpdir', $args{tmp_dir}
		);

	if (defined($args{fusion_inspect})) {
		$star_command .= join(' ',
			' --FusionInspector', $args{fusion_inspect},
			'--left_fq', $args{r1},
			'--right_fq', $args{r2}
			);

		if ('inspect' eq $args{fusion_inspect}) {
			$star_command .= ' --extract_fusion_reads';
			}
		}

	return($star_command);
	}

### MAIN ##########################################################################################
sub main {
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
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'star-fusion');
	$tool_data->{date} = strftime "%F", localtime;

	# clean up reference_dir (aesthetic reasons only)
	$tool_data->{reference_dir} =~ s/\/$//;

	# check for resume and confirm output directories
	my ($resume, $output_directory, $log_directory) = set_output_path(tool_data => $tool_data);

	# start logging
	print "---\n";
	print "Running STAR-fusion pipeline.\n";
	print "\n  Tool config used: $tool_config";
	if (defined($tool_data->{tool_path})) {
		print "\n    STAR-fusion path: $tool_data->{tool_path}";
		}
	print "\n    STAR-fusion reference directory: $tool_data->{reference_dir}";
	print "\n    Output directory: $output_directory";
	print "\n  Sample config used: $data_config";
	print "\n---";

	# set tools and versions
	my $star_fusion = $tool_data->{tool} . '/' . $tool_data->{tool_version};
	if (defined($tool_data->{tool_path})) {
		$star_fusion = '';
		}
	my $star	= 'STAR/' . $tool_data->{star_version};
	my $samtools	= 'samtools/' . $tool_data->{samtools_version};
	my $perl	= 'perl/5.30.0';

	# create a file to hold job metrics
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

	### RUN ############################################################################################
	# get sample data
	my $smp_data = LoadFile($data_config);

	my ($run_script, $run_id, $raw_link, $final_link);
	my @all_jobs;

	# process each patient in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print "\nInitiating process for PATIENT: $patient\n";

		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};

		my @samples = @tumour_ids;
		if (scalar(@normal_ids) > 0) { push @samples, @normal_ids; }

		my (@final_outputs, @patient_jobs);
		my $cleanup_cmd;

		# process each separate sample for this patient
		foreach my $sample (@samples) {

			print "  SAMPLE: $sample\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			my $link_directory = join('/', $sample_directory, 'input_links');
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
			my $junctions_file = join('/', $data_dir, $sample, 'Chimeric.out.junction');
			print "    STAR chimeric junctions: $junctions_file\n\n";

			# create a symlink for this file
			my @tmp = split /\//, $junctions_file;
			$raw_link = join('/', $link_directory, 'Chimeric.out.junction');
			symlink($junctions_file, $raw_link);

			# reset run_id for this sample
			$run_id = '';
			my @smp_jobs;

			# if we will be running FusionInspect validate, we will need the fastq files as well
			my ($r1, $r2);
			my (@r1_fastq_files, @r2_fastq_files);
			if (defined($tool_data->{FusionInspect})) {

				$data_dir = join('/', $data_dir, $sample, 'fastq_links');
				opendir(RAWFILES, $data_dir) or die "Cannot open $data_dir !";
				my @dir_files = readdir(RAWFILES);
				@r1_fastq_files = grep {/R1.fastq.gz/} @dir_files;
				@r2_fastq_files = grep {/R2.fastq.gz/} @dir_files;
				closedir(RAWFILES);

				# if there were multiple lanes, we will need to combine them
				$r1 = join('/', $data_dir, $r1_fastq_files[0]);
				$r2 = join('/', $data_dir, $r2_fastq_files[0]);

				if (scalar(@r1_fastq_files) > 1) {

					$r1 = join('/', $link_directory, $sample . '_combined_lanes.R1.fastq');
					$r2 = join('/', $link_directory, $sample . '_combined_lanes.R2.fastq');

					my $cat_fq_cmd = "cd $data_dir";
					$cat_fq_cmd .= "\necho Concatenating fastq files...";

					$cat_fq_cmd .= join(' ',
						"\nzcat",
						join(' ', @r1_fastq_files),
						'>', $r1
						);

					$cat_fq_cmd .= join(' ',
						"\nzcat",
						join(' ', @r2_fastq_files),
						'>', $r2
						);

					$cat_fq_cmd .= "\necho Finished concatenating files...";

					my $gzip_fq_cmd = "echo Compressing concatenated fastq files...";

					$gzip_fq_cmd .= "\ngzip " . $r1;
					$gzip_fq_cmd .= "\ngzip " . $r2;
					$gzip_fq_cmd .= "\necho Finished compressing fastq files. Now ready for FusionInspector!";

					# record command (in log directory) and then run job
					print "Submitting job to prepare input for FusionInspector...\n";

					$run_script = write_script(
						log_dir	=> $log_directory,
						name	=> 'run_prepare_fastq_for_FusionInspector_' . $sample,
						cmd	=> $cat_fq_cmd . "\n" . $gzip_fq_cmd,
						max_time	=> '04:00:00',
						mem		=> '1G',
						hpc_driver	=> $tool_data->{HPC_driver}
						);

					$run_id = submit_job(
						jobname		=> 'run_prepare_fastq_for_FusionInspector_' . $sample,
						shell_command	=> $run_script,
						hpc_driver	=> $tool_data->{HPC_driver},
						dry_run		=> $tool_data->{dry_run}
						);

					$r1 .= '.gz';
					$r2 .= '.gz';

					push @smp_jobs, $run_id;
					}
				}

			## run STAR-Fusion on these junctions
			my $fusion_output = join('/', $sample_directory, 'star-fusion.fusion_predictions.abridged.tsv');

			my $fusion_cmd = get_star_fusion_command(
				fusion_call	=> $tool_data->{tool_path},
				reference	=> $tool_data->{reference_dir},
				input		=> $junctions_file,
				output_dir	=> $sample_directory,
				tmp_dir		=> $tmp_directory,
				fusion_inspect	=> $tool_data->{FusionInspect},
				r1		=> $r1,
				r2		=> $r2
				);

			# check if this should be run
			if ( ('N' eq $resume) || ('Y' eq missing_file($fusion_output))) {

				# record command (in log directory) and then run job
				print "Submitting job to run STAR-Fusion...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_STAR-fusion_' . $sample,
					cmd	=> $fusion_cmd,
					modules => [$star, $perl, $samtools, 'tabix', 'python', $star_fusion],
					# requires python igv-reports
					dependencies	=> $run_id,
					max_time	=> $tool_data->{parameters}->{star_fusion}->{time},
					mem		=> $tool_data->{parameters}->{star_fusion}->{mem},
					hpc_driver	=> $tool_data->{HPC_driver},
					cpus_per_task	=> 4
					);

				$run_id = submit_job(
					jobname		=> 'run_STAR-Fusion_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $tool_data->{HPC_driver},
					dry_run		=> $tool_data->{dry_run}
					);

				push @smp_jobs, $run_id;
				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;

				# add some stuff to the cleanup
				$cleanup_cmd .= "\nrm $sample_directory/pipeliner*";
				$cleanup_cmd .= "\nrm -rf $sample_directory/_starF_checkpoints";
				$cleanup_cmd .= "\nrm $sample_directory/*.ok";

				# IF THIS STEP IS SUCCESSFULLY RUN,
				# create a symlink for the final output in the TOP directory
				my $smp_output = $sample . "_fusion_predictions.abridged.tsv";
				my $links_cmd = join("\n",
					"cd $patient_directory",
					"ln -s $fusion_output $smp_output",
					"cd $tool_data->{output_dir}"
					);

				if (-l $smp_output) { unlink $smp_output or die "Failed to remove previous symlink: $smp_output;\n"; }
				$links_cmd .= "\nln -s $fusion_output $smp_output";

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
				print "Skipping STAR-Fusion because output already exists...\n";
				}

			# add output from STAR-Fusion to final_outputs
			push @final_outputs, $fusion_output;
			$cleanup_cmd .= "\nrm -rf " . join('/', 
				$sample_directory,
				'star-fusion.preliminary',
				'star-fusion.filter.intermediates_dir'
				);
			}

		# remove temporary directories (once per patient)
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
				log_dir => $log_directory,
				name    => 'run_cleanup_' . $patient,
				cmd     => $cleanup_cmd,
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
			job_ids => join(',', @all_jobs),
			outfile => $outfile
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
			dry_run		=> 'N'
			);
		}

	# final job to output a BAM config for downstream stuff
	if ('Y' eq $tool_data->{create_output_yaml}) {

		print "Creating config yaml for output fusion calls...\n";

		my $output_yaml_cmd = join(' ',
			"perl $cwd/shared/create_final_yaml.pl",
			'-d', $output_directory,
			'-o', $output_directory . '/fusions_config.yaml',
			'-p', 'abridged.tsv'
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'output_final_yaml',
			cmd	=> $output_yaml_cmd,,
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

# do some quick error checks to ensure valid input	
if (!defined($tool_config)) { die("No tool config file defined; please provide -t | --tool (ie, tool_config.yaml)"); }
if (!defined($data_config)) { die("No data config file defined; please provide -c | --config (ie, sample_config.yaml)"); }

main(tool_config => $tool_config, data_config => $data_config);
