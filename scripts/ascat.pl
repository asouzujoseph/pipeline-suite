#!/usr/bin/env perl
### ascat.pl #######################################################################################
use AutoLoader 'AUTOLOAD';
use strict;
use warnings;
use version;
use Carp;
use Getopt::Std;
use Getopt::Long;
use POSIX qw(strftime);
use File::Basename;
use File::Path qw(make_path);
use YAML qw(LoadFile);
use List::Util qw(any sum);
use IO::Handle;

my $cwd = dirname(__FILE__);
require "$cwd/utilities.pl";

our ($ref_type, $intervals_bed, $r_lib, $ascat_path, $ascat_ref);

####################################################################################################
# version	author		comment
# 1.0		sprokopec	script to run ASCAT

### USAGE ##########################################################################################
# ascat.pl -t tool.yaml -d data.yaml -o /path/to/output/dir -c slurm --remove --dry_run
#
# where:
# 	-t (tool.yaml) contains tool versions and parameters, reference information, etc.
# 	-d (data.yaml) contains sample information (YAML file containing paths to BWA-aligned,
# 	GATK-processed BAMs, generated by gatk.pl)
# 	-o (/path/to/output/dir) indicates tool-specific output directory
# 	-c indicates hpc driver (ie, slurm)
# 	--remove indicates that intermediates will be removed
# 	--dry_run indicates that this is a dry run

### DEFINE SUBROUTINES #############################################################################
# format command to run ASCAT
sub get_ascat_command {
	my %args = (
		tumour_id	=> undef,
		tumour_bam	=> undef,
		normal_bam	=> undef,
		tmp_dir		=> undef,
		out_dir		=> undef,
		n_cpus		=> 1,
		@_
		);

	my $ascat_command = join(' ',
		'Rscript', $ascat_path,
		'--tumour_bam', $args{tumour_bam},
		'--normal_bam', $args{normal_bam},
		'--sample_name', $args{tumour_id},
		'--working_dir', $args{tmp_dir},
		'--out_dir', $args{out_dir},
		'--genome_build', $ref_type,
		'--ref_file', $ascat_ref,
		'--n_threads', $args{n_cpus}
		);

	if (defined($r_lib)) {
		$ascat_command .= " --lib_paths $r_lib";
		}

	return($ascat_command);
	}

### MAIN ###########################################################################################
sub main {
	my %args = (
		tool_config		=> undef,
		data_config		=> undef,
		output_directory	=> undef,
		hpc_driver		=> undef,
		del_intermediates	=> undef,
		dry_run			=> undef,
		no_wait			=> undef,
		@_
		);

	my $tool_config = $args{tool_config};
	my $data_config = $args{data_config};

	### PREAMBLE ######################################################################################
	unless($args{dry_run}) {
		print "Initiating ASCAT pipeline...\n";
		}

	# load tool config
	my $tool_data_orig = LoadFile($tool_config);
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'ascat');

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_ASCAT_pipeline.log');

	# create a file to hold job metrics
	my (@files, $run_count, $outfile, $touch_exit_status);
	unless ($args{dry_run}) {
		# initiate a file to hold job metrics
		opendir(LOGFILES, $log_directory) or die "Cannot open $log_directory";
		@files = grep { /slurm_job_metrics/ } readdir(LOGFILES);
		$run_count = scalar(@files) + 1;
		closedir(LOGFILES);

		$outfile = $log_directory . '/slurm_job_metrics_' . $run_count . '.out';
		$touch_exit_status = system("touch $outfile");
		if (0 != $touch_exit_status) { Carp::croak("Cannot touch file $outfile"); }

		$log_file = join('/', $log_directory, 'run_ASCAT_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";
	$log->autoflush;

	print $log "---\n";
	print $log "Running ASCAT pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Reference used: $tool_data->{reference}";

	$ref_type = $tool_data->{ref_type};

	my $snp6_file;
	if ( ('GRCh38' eq $ref_type) || ('hg38' eq $ref_type) ) {
		$snp6_file	= '/cluster/projects/pughlab/references/ASCAT_refs/GRCh38_SNP6.tsv.gz';
		} elsif ( ('GRCh37' eq $ref_type) || ('hg19' eq $ref_type)) {
		$snp6_file	= '/cluster/projects/pughlab/references/ASCAT_refs/GRCh37_SNP6.tsv.gz';
		} else {
		die('Unrecognized reference type requested!');
		}

	print $log "\n      Using ASCAT reference file: $snp6_file";
	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---\n";

	# get user-specified tool parameters
	my $parameters = $tool_data->{ascat}->{parameters};

	# set tools and versions
	$ascat_path	= "$cwd/runASCAT.R";
	my $r_version	= 'R/'. $tool_data->{ascat_r_version};

	if (defined($parameters->{ascat_lib_path})) {
		$r_lib = $parameters->{ascat_lib_path};
		}

	# get optional HPC group
	my $hpc_group = defined($tool_data->{hpc_group}) ? "-A $tool_data->{hpc_group}" : undef;

	### RUN ###########################################################################################
	my ($run_script, $run_id, $link, $cleanup_cmd, $should_run_final);
	my @all_jobs;

	# get sample data
	my $smp_data = LoadFile($data_config);

	# do an initial check for normals; no normals = don't bother running
	my @has_normals;
	foreach my $patient (sort keys %{$smp_data}) {
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		if (scalar(@normal_ids) > 0) { push @has_normals, $patient; }
		}

	if (scalar(@has_normals) == 0) {
		die("No normals provided. ASCAT requires matched normals, therefore we will exit now.");
		}

	# prep ASCAT reference file (SNP6)
	my $prep_ref_run_id = '';
	$ascat_ref = join('/', $output_directory, 'ascat_SNP6_reference.tsv');
	
	# should the 'chr' prefix be added?
	if ( ('GRCh37' eq $ref_type) || ('GRCh37' eq $ref_type) ) {

		$ascat_ref .= $ascat_ref . '.gz';
		symlink($snp6_file, $ascat_ref);

		} elsif ( ('hg38' eq $ref_type) || ('hg19' eq $ref_type)) {
		my $prep_ref_command = join('', 'zcat ', $snp6_file, ' | sed s/^/chr/g > ', $ascat_ref);
		$prep_ref_command .= "\ngzip $ascat_ref";

		$ascat_ref .= '.gz';

		# check if this should be run
		if ('Y' eq missing_file($ascat_ref)) {

			# record command (in log directory) and then run job
			print $log "Submitting job for PrepSNP6...\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_prep_ascat_reference',
				cmd	=> $prep_ref_command,
				modules	=> [$r_version],
				max_time	=> '02:00:00',
				mem		=> '1G',
				hpc_driver	=> $args{hpc_driver},
				extra_args	=> [$hpc_group]
				);

			$prep_ref_run_id = submit_job(
				jobname		=> 'run_prep_ascat_reference', 
				shell_command	=> $run_script,
				hpc_driver	=> $args{hpc_driver},
				dry_run		=> $args{dry_run},
				log_file	=> $log
				);

			push @all_jobs, $prep_ref_run_id;
			} else {
			print $log "Skipping PreprocessIntervals as this has already been completed!\n";
			}
		}

	# begin processing...
	unless($args{dry_run}) {
		print "Processing " . scalar(keys %{$smp_data}) . " patients.\n";
		}

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient\n";

		# find bams
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};	
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};

		if (scalar(@normal_ids) == 0) {
			print $log "\n>>No normal BAM provided. Skipping ASCAT for $patient...\n";
			next;
			}

		# create some directories
		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my $link_directory = join('/', $patient_directory, 'bam_links');
		unless(-e $link_directory) { make_path($link_directory); }

		# create some symlinks
		foreach my $normal (@normal_ids) {
			my $bam = $smp_data->{$patient}->{normal}->{$normal};
			$link = join('/', $link_directory, basename($bam));
			symlink($bam, $link);
			}
		foreach my $tumour (@tumour_ids) {
			my $bam = $smp_data->{$patient}->{tumour}->{$tumour};
			$link = join('/', $link_directory, basename($bam));
			symlink($bam, $link);
			}

		# create an array to hold final outputs and all patient job ids
		my (@final_outputs, @patient_jobs);
		$cleanup_cmd = '';

		# now, for each tumour sample
		foreach my $sample (@tumour_ids) {

			# if there are any samples to run, we will run the final combine job
			$should_run_final = 1;

			print $log "  SAMPLE: $sample\n\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			my $tmp_directory = join('/', $sample_directory, 'TEMP');
			unless(-e $tmp_directory) { make_path($tmp_directory); }

			$cleanup_cmd .= "rm -rf $tmp_directory\n";

			# create command to run ASCAT
			my $ascat_command = get_ascat_command(
				tumour_id	=> $sample,
				tumour_bam	=> $smp_data->{$patient}->{tumour}->{$sample},
				normal_bam	=> $smp_data->{$patient}->{normal}->{$normal_ids[0]},
				tmp_dir		=> $tmp_directory,
				out_dir		=> $sample_directory,
				n_cpus		=> $parameters->{ascat}->{n_cpus}
				);

			my $ascat_output = '';

			# check if this should be run
			if ('Y' eq missing_file($ascat_output)) {

				# record command (in log directory) and then run job
				print $log "Submitting job for ASCAT...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_ascat_' . $sample,
					cmd	=> $ascat_command,
					modules	=> [$r_version],
					dependencies	=> $prep_ref_run_id,
					max_time	=> $parameters->{ascat}->{time},
					mem		=> $parameters->{ascat}->{mem},
					cpus_per_task	=> $parameters->{ascat}->{n_cpus},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_ascat_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				} else {
				print $log "Skipping ASCAT step because this has already been completed!\n";
				}

			push @final_outputs, $ascat_output;
			}

		# should intermediate files be removed
		# run per patient
		if ($args{del_intermediates}) {

			if (scalar(@patient_jobs) > 0) {

				print $log "Submitting job to clean up temporary/intermediate files...\n";

				# make sure final output exists before removing intermediate files!
				$cleanup_cmd = join("\n",
					"if [ -s " . join(" ] && [ -s ", @final_outputs) . " ]; then",
					"  $cleanup_cmd",
					"else",
					'  echo "One or more FINAL OUTPUT FILES is missing; not removing intermediates"',
					"fi"
					);

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_cleanup_' . $patient,
					cmd	=> $cleanup_cmd,
					dependencies	=> join(':', @patient_jobs),
					mem		=> '256M',
					hpc_driver	=> $args{hpc_driver},
					kill_on_error	=> 0,
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_cleanup_' . $patient,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);
				}
			}

		print $log "\nFINAL OUTPUT:\n" . join("\n  ", @final_outputs) . "\n";
		print $log "---\n";
		}

	# collate results
	if ($should_run_final) {

		my $collect_output = join(' ',
			"Rscript $cwd/collect_ascat_output.R",
			'-d', $output_directory,
			'-p', $tool_data->{project_name},
			'-r', $tool_data->{ref_type}
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'combine_ascat_output',
			cmd	=> $collect_output,
			modules	=> [$r_version],
			dependencies	=> join(':', @all_jobs),
			mem		=> '4G',
			max_time	=> '12:00:00',
			hpc_driver	=> $args{hpc_driver},
			extra_args	=> [$hpc_group]
			);

		$run_id = submit_job(
			jobname		=> 'combine_ascat_output',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $run_id;
		}

	# if this is not a dry run OR there are jobs to assess (run or resumed with jobs submitted) then
	# collect job metrics (exit status, mem, run time)
	unless ( ($args{dry_run}) || (scalar(@all_jobs) == 0) ) {

		# collect job stats
		my $collect_metrics = collect_job_stats(
			job_ids		=> join(',', @all_jobs),
			outfile		=> $outfile,
			hpc_driver	=> $args{hpc_driver}
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'output_job_metrics_' . $run_count,
			cmd	=> $collect_metrics,
			dependencies	=> join(':', @all_jobs),
			mem		=> '256M',
			hpc_driver	=> $args{hpc_driver},
			kill_on_error	=> 0,
			extra_args	=> [$hpc_group]
			);

		$run_id = submit_job(
			jobname		=> 'output_job_metrics',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $run_id;

		# do some logging
		print "Number of jobs submitted: " . scalar(@all_jobs) . "\n";

		my $n_queued = `squeue -r | wc -l`;
		print "Total number of jobs in queue: " . $n_queued . "\n";

		# wait until it finishes
		unless ($args{no_wait}) {
			check_final_status(job_id => $run_id);
			}
		}

	# finish up
	print $log "\nProgramming terminated successfully.\n\n";
	close $log;
	}

### GETOPTS AND DEFAULT VALUES #####################################################################
# declare variables
my ($tool_config, $data_config, $output_directory);
my $hpc_driver = 'slurm';
my ($remove_junk, $dry_run, $help, $no_wait);

# get command line arguments
GetOptions(
	'h|help'	=> \$help,
	'd|data=s'	=> \$data_config,
	't|tool=s'	=> \$tool_config,
	'o|out_dir=s'	=> \$output_directory,
	'c|cluster=s'	=> \$hpc_driver,
	'remove'	=> \$remove_junk,
	'dry-run'	=> \$dry_run,
	'no-wait'	=> \$no_wait
	);

if ($help) {
	my $help_msg = join("\n",
		"Options:",
		"\t--help|-h\tPrint this help message",
		"\t--data|-d\t<string> data config (yaml format)",
		"\t--tool|-t\t<string> tool config (yaml format)",
		"\t--out_dir|-o\t<string> path to output directory",
		"\t--cluster|-c\t<string> cluster scheduler (default: slurm)",
		"\t--remove\t<boolean> should intermediates be removed? (default: false)",
		"\t--dry-run\t<boolean> should jobs be submitted? (default: false)",
		"\t--no-wait\t<boolean> should we exit after job submission (true) or wait until all jobs have completed (false)? (default: false)"
		);

	print "$help_msg\n";
	exit;
	}

# do some quick error checks to confirm valid arguments	
if (!defined($tool_config)) { die("No tool config file defined; please provide -t | --tool (ie, tool_config.yaml)"); }
if (!defined($data_config)) { die("No data config file defined; please provide -d | --data (ie, sample_config.yaml)"); }
if (!defined($output_directory)) { die("No output directory defined; please provide -o | --out_dir"); }

main(
	tool_config		=> $tool_config,
	data_config		=> $data_config,
	output_directory	=> $output_directory,
	hpc_driver		=> $hpc_driver,
	del_intermediates	=> $remove_junk,
	dry_run			=> $dry_run,
	no_wait			=> $no_wait
	);
