#!/usr/bin/env perl
### mavis.pl #######################################################################################
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
use List::Util qw(any);
use File::Find;

my $cwd = dirname($0);
require "$cwd/utilities.pl";

# define some global variables
our ($reference, $exclude_regions) = undef;

####################################################################################################
# version       author		comment
# 1.0		sprokopec       script to run MAVIS SV annotator

### USAGE ##########################################################################################
# mavis.pl -t tool_config.yaml -d data_config.yaml -o /path/to/output/dir -c slurm --remove --dry_run \
# 	--manta /path/to/manta/dir --delly /path/to/delly/dir
#
# where:
#	-t (tool.yaml) contains tool versions and parameters, reference information, etc.
#	-d (data.yaml) contains sample information (YAML file containing paths to BWA-aligned,
#		GATK-processed BAMs, generated by gatk.pl)
#	-o (/path/to/output/dir) indicates tool-specific output directory
#	--manta (/path/to/manta/dir) indicates Manta (Strelka) directory where SV calls can be found
#	--delly (/path/to/delly/dir) indicates Delly directory where SV calls can be found
#	-c indicates hpc driver (ie, slurm)
#	--remove indicates that intermediates will be removed
#	--dry_run indicates that this is a dry run

### DEFINE SUBROUTINES #############################################################################
# find files recursively
sub _get_files {
	my ($dirs, $exten) = @_;

	my @files;
	my $want = sub {
		-f && /\Q$exten\E$/ && push @files, $File::Find::name
		};

	find($want, @{$dirs});
	return(@files);
	}

# format command to run Manta
sub get_mavis_command {
	my %args = (
		tumour_id	=> undef,
		normal_id	=> undef,
		tumour_bam	=> undef,
		normal_bam	=> undef,
		manta		=> undef,
		delly		=> undef,
		output		=> undef,
		@_
		);

	if ($args{tumour_id} =~ m/^\d/) { $args{tumour_id} = 'X' . $args{tumour_id}; }
	if ($args{normal_id} =~ m/^\d/) { $args{normal_id} = 'X' . $args{normal_id}; }

	my $mavis_cmd = join(' ',
		'mavis config',
		'-w', $args{output},
		'--library', $args{tumour_id}, 'genome diseased False', $args{tumour_bam},
		'--convert delly', $args{delly}, 'delly',
		'--convert manta', $args{manta}, 'manta',
		'--assign', $args{tumour_id}, 'manta delly'
		);

	if (defined($args{normal_id})) {
		$mavis_cmd .= ' ' . join(' ',
			'--library', $args{normal_id}, 'genome normal False', $args{normal_bam},
			'--assign', $args{normal_id}, 'manta delly'
			);
		}

	return($mavis_cmd);
	}

### MAIN ###########################################################################################
sub main {
	my %args = (
		tool_config		=> undef,
		data_config		=> undef,
		output_directory	=> undef,
		manta_dir		=> undef,
		delly_dir		=> undef,
		hpc_driver		=> undef,
		del_intermediates	=> undef,
		dry_run			=> undef,
		dependencies		=> '',
		@_
		);

	my $tool_config = $args{tool_config};
	my $data_config = $args{data_config};

	### PREAMBLE ######################################################################################

	# load tool config
	my $tool_data_orig = LoadFile($tool_config);
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'mavis');

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_MAVIS_pipeline.log');

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

		$log_file = join('/', $log_directory, 'run_MAVIS_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";

	print $log "---\n";
	print $log "Running Mavis SV annotation pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n  Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n    Manta directory: $args{manta_dir}";
	print $log "\n    Delly directory: $args{delly_dir}";
	print $log "\n---";

	# set tools and versions
	my $mavis	= 'mavis/' . $tool_data->{tool_version};
	my $bwa		= 'bwa/' . $tool_data->{bwa_version};

	my $mavis_export = join("\n",
		"export MAVIS_ANNOTATIONS=$tool_data->{mavis_annotations}",
		"export MAVIS_MASKING=$tool_data->{mavis_masking}",
		"export MAVIS_DGV_ANNOTATION=$tool_data->{mavis_dgv_anno}",
		"export MAVIS_TEMPLATE_METADATA=$tool_data->{mavis_cytoband}",
		"export MAVIS_REFERENCE_GENOME=$tool_data->{reference}",
		"export MAVIS_ALIGNER='$tool_data->{mavis_aligner}'",
		"export MAVIS_ALIGNER_REFERENCE=$tool_data->{bwa_ref}",
		"export MAVIS_DRAW_FUSIONS_ONLY=False",
		"export MAVIS_SCHEDULER=" . uc($args{hpc_driver})
		);

	### RUN ###########################################################################################
	# get sample data
	my $smp_data = LoadFile($data_config);

	# find manta and delly outputs
	my @sv_directories = ($args{manta_dir}, $args{delly_dir});
	my @extensions = qw(diploidSV.vcf.gz somaticSV.vcf.gz tumorSV.vcf.gz Delly_SVs_somatic_hc.bcf);

	my @sv_files;
	foreach my $extension ( @extensions ) {
		push @sv_files, _get_files(\@sv_directories, $extension);
		}

	my @manta_files = grep { /Manta/ } @sv_files;
	my @delly_files = grep { /Delly/ } @sv_files;

	# initialize objects
	my ($run_script, $run_id, $link);
	my @all_jobs;

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient\n";

		# find bams
		my @normal_ids = sort keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = sort keys %{$smp_data->{$patient}->{'tumour'}};

		if (scalar(@tumour_ids) == 0) {
			print $log "\n>> No tumour BAM provided, skipping patient.\n";
			next;
			}

		# create some directories
		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my $link_directory = join('/', $patient_directory, 'input_links');
		unless(-e $link_directory) { make_path($link_directory); }

		# create some symlinks and add samples to sheet
		foreach my $normal (@normal_ids) {
			my @tmp = split /\//, $smp_data->{$patient}->{normal}->{$normal};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{normal}->{$normal}, $link);
			}

		foreach my $tumour (@tumour_ids) {

			my @tmp = split /\//, $smp_data->{$patient}->{tumour}->{$tumour};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{tumour}->{$tumour}, $link);

			my @delly_svs = grep { /$tumour/ } @delly_files;
			$link = join('/', $link_directory, $tumour . '_Delly_SVs.bcf');
			symlink($delly_svs[0], $link);

			my @manta_svs = grep { /$tumour/ } @manta_files;
			foreach my $file ( @manta_svs ) {
				my @tmp = split /\//, $file;
				$link = join('/', $link_directory, $tumour . '_Manta_' . $tmp[-1]);
				symlink($file, $link);
				}
			}

		# run mavis commands over each tumour
		foreach my $sample ( @tumour_ids ) {

			print $log "  SAMPLE: $sample\n\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			my @manta_svs = grep { /$sample/ } @manta_files;
			my @delly_svs = grep { /$sample/ } @delly_files;

			# first, format input files
			my (@manta_svs_formatted, @format_jobs);
			my $format_command;

			foreach my $file ( @manta_svs ) {
				my @tmp = split /\//, $file;
				my $stem = $tmp[-1];
				$stem =~ s/.gz//;
				my $formatted_vcf = join('/', $sample_directory, 'Manta_formatted_' . $stem);

				# write command to format manta SVs (older version of Manta required for mavis)
				$format_command .= "\n\n" . join(' ',
					'python /cluster/tools/software/centos7/manta/1.6.0/libexec/convertInversion.py',
					'/cluster/tools/software/centos7/samtools/1.9/bin/samtools',
					$tool_data->{reference},
					$file,
					'>', $formatted_vcf
					);

				push @manta_svs_formatted, $formatted_vcf;
				}

			# check if this should be run
			if ('Y' eq missing_file(@manta_svs_formatted)) {

				# record command (in log directory) and then run job
				print $log "Submitting job to format Manta SVs...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_format_manta_svs_for_mavis_' . $sample,
					cmd	=> $format_command,
					modules	=> ['python/2.7'],
					dependencies	=> $args{dependencies},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_format_manta_svs_for_mavis_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @format_jobs, $run_id;
				push @all_jobs, $run_id;
				}
			else {
				print $log "Skipping format manta step because this has already been completed!\n";
				}

			# now, run mavis (config, setup, schedule)
			my $mavis_cmd = "\n" . $mavis_export;
			my $mavis_cfg = join('/', $sample_directory, 'mavis.cfg');
			my $mavis_output;

			# run on tumour-only
			if (scalar(@normal_ids) == 0) {

				$mavis_output = join('/',
					$sample_directory,
					'summary',
					"mavis_summary_all\_$sample.tab"
					);

				$mavis_cmd .= "\n\n" . get_mavis_command(
					tumour_id	=> $sample,
					tumour_bam	=> $smp_data->{$patient}->{tumour}->{$sample},
					delly		=> $delly_svs[0],
					manta		=> join(' ', @manta_svs_formatted),
					output		=> $mavis_cfg
					);

				} else { # run on T/N pairs

				$mavis_output = join('/',
					$sample_directory,
					'summary',
					"mavis_summary_all_$normal_ids[0]\_$sample.tab"
					);

				$mavis_cmd .= "\n\n" . get_mavis_command(
					tumour_id	=> $sample,
					normal_id	=> $normal_ids[0],
					tumour_bam	=> $smp_data->{$patient}->{tumour}->{$sample},
					normal_bam	=> $smp_data->{$patient}->{normal}->{$normal_ids[0]},
					manta		=> join(' ', @manta_svs_formatted),
					delly		=> $delly_svs[0],
					output		=> $mavis_cfg
					);
				}

			$mavis_cmd .= "\n\n" . "mavis setup $mavis_cfg -o $sample_directory";

			# if build.cfg already exists, then try resubmitting
			if ('N' eq missing_file("$sample_directory/build.cfg")) {
				$mavis_cmd .= "\n\n" . "mavis schedule -o $sample_directory --resubmit";
				} else {
				$mavis_cmd .= "\n\n" . "mavis schedule -o $sample_directory --submit";
				}

			$mavis_cmd .= "\n\n" . join("\n",
				"if [ -s $mavis_output ]; then",
				"  exit 0",
				"else",
				"  exit 1",
				"fi"
				);

			# check if this should be run
			if ('Y' eq missing_file($mavis_output)) {

				# record command (in log directory) and then run job
				print $log "Submitting job for MAVIS SV annotator...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_mavis_sv_annotator_' . $sample,
					cmd	=> $mavis_cmd,
					modules	=> [$mavis, $bwa],
					dependencies	=> join(',', $args{dependencies}, @format_jobs),
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_mavis_sv_annotator_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @all_jobs, $run_id;
				}
			else {
				print $log "Skipping MAVIS because this has already been completed!\n";
				}
			}
		}

	# should job metrics be collected
	unless ($args{dry_run}) {

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
			mem		=> '256M',
			hpc_driver	=> $args{hpc_driver}
			);

		$run_id = submit_job(
			jobname		=> 'output_job_metrics',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);
		}

	# finish up
	print $log "\nProgramming terminated successfully.\n\n";
	close $log;
	}

### GETOPTS AND DEFAULT VALUES #####################################################################
# declare variables
my ($tool_config, $data_config, $output_directory, $manta_directory, $delly_directory);
my $hpc_driver = 'slurm';
my ($remove_junk, $dry_run);
my $dependencies = '';

my $help;

# get command line arguments
GetOptions(
	'h|help'	=> \$help,
	'd|data=s'	=> \$data_config,
	't|tool=s'	=> \$tool_config,
	'o|out_dir=s'	=> \$output_directory,
	'm|manta=s'	=> \$manta_directory,
	'e|delly=s'	=> \$delly_directory,
	'c|cluster=s'	=> \$hpc_driver,
	'remove'	=> \$remove_junk,
	'dry_run'	=> \$dry_run,
	'depends=s'	=> \$dependencies
	);

if ($help) {
	my $help_msg = join("\n",
		"Options:",
		"\t--help|-h\tPrint this help message",
		"\t--data|-d\t<string> data config (yaml format)",
		"\t--tool|-t\t<string> tool config (yaml format)",
		"\t--out_dir|-o\t<string> path to output directory",
		"\t--manta|-m\t<string> path to manta (strelka) output directory",
		"\t--delly|-D\t<string> path to delly output directory",
		"\t--cluster|-c\t<string> cluster scheduler (default: slurm)",
		"\t--remove\t<boolean> should intermediates be removed? (default: false)",
		"\t--dry_run\t<boolean> should jobs be submitted? (default: false)",
		"\t--depends\t<string> comma separated list of dependencies (optional)"
		);

	print $help_msg;
	exit;
	}

# do some quick error checks to confirm valid arguments	
if (!defined($tool_config)) { die("No tool config file defined; please provide -t | --tool (ie, tool_config.yaml)"); }
if (!defined($data_config)) { die("No data config file defined; please provide -d | --data (ie, sample_config.yaml)"); }
if (!defined($output_directory)) { die("No output directory defined; please provide -o | --out_dir"); }
if (!defined($manta_directory)) { die("No manta directory defined; please provide -m | --manta"); }
if (!defined($delly_directory)) { die("No delly directory defined; please provide -e | --delly"); }

main(
	tool_config		=> $tool_config,
	data_config		=> $data_config,
	output_directory	=> $output_directory,
	manta_dir		=> $manta_directory,
	delly_dir		=> $delly_directory,
	hpc_driver		=> $hpc_driver,
	del_intermediates	=> $remove_junk,
	dry_run			=> $dry_run,
	dependencies		=> $dependencies
	);
