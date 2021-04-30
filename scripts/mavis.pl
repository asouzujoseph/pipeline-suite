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
use Data::Dumper;

use IO::Handle;

my $cwd = dirname($0);
require "$cwd/utilities.pl";

# define some global variables
our ($reference, $exclude_regions) = undef;

####################################################################################################
# version       author		comment
# 1.0		sprokopec       script to run MAVIS SV annotator
# 1.1           sprokopec       minor updates for tool config

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
		-e && /\Q$exten\E$/ && push @files, $File::Find::name
		};

	find($want, $dirs);
	return(@files);
	}

# format command to run Manta
sub get_mavis_command {
	my %args = (
		tumour_ids	=> [],
		tumour_bams	=> undef,
		rna_ids		=> [],
		rna_bams	=> undef,
		normal_id	=> undef,
		normal_bam	=> undef,
		manta		=> undef,
		delly		=> undef,
		starfusion	=> undef,
		fusioncatcher	=> undef,
		output		=> undef,
		@_
		);

	my $mavis_cmd = join(' ',
		'mavis config',
		'-w', $args{output},
		'--convert delly', $args{delly}, 'delly',
		'--convert manta', $args{manta}, 'manta'
		);

	foreach my $smp ( @{$args{tumour_ids}} ) {

		my $id = $smp;
		if ($smp =~ m/^\d/) {
			$id = 'X' . $smp;
			}
		$id =~ s/_/-/g;

		$mavis_cmd .= ' ' . join(' ',
			'--library', $id, 'genome diseased False', $args{tumour_bams}->{$smp},
			'--assign', $id, 'manta delly'
			);
		}

	if (defined($args{normal_id})) {

		my $id = $args{normal_id};
		if ($args{normal_id} =~ m/^\d/) {
			$id = 'X' . $args{normal_id};
			}
		$id =~ s/_/-/g;

		$mavis_cmd .= ' ' . join(' ',
			'--library', $id, 'genome normal False', $args{normal_bam},
			'--assign', $id, 'manta delly'
			);
		}

	if (scalar(@{$args{rna_ids}}) > 0) {

		$mavis_cmd .= ' ' . join(' ',
			'--convert starfusion', $args{starfusion}, 'starfusion',
			'--external_conversion fusioncatcher "Rscript',
			"$cwd/convert_fusioncatcher.R",
			$args{fusioncatcher} . '"'
			);

		foreach my $smp ( @{$args{rna_ids}} ) {

			my $id = $smp;
			if ($smp =~ m/^\d/) {
				$id = 'X' . $smp;
				}
			$id =~ s/_/-/g;
			$id .= '-rna';

			$mavis_cmd .= ' ' . join(' ',
				'--library', $id, 'transcriptome diseased True', $args{rna_bams}->{$smp},
				'--assign', $id, 'starfusion fusioncatcher'
				);
			}
		}

	return($mavis_cmd);
	}

### MAIN ###########################################################################################
sub main {
	my %args = (
		tool_config		=> undef,
		dna_config		=> undef,
		rna_config		=> undef,
		output_directory	=> undef,
		manta_dir		=> undef,
		delly_dir		=> undef,
		starfusion_dir		=> undef,
		fusioncatcher_dir	=> undef,
		hpc_driver		=> undef,
		del_intermediates	=> undef,
		dry_run			=> undef,
		no_wait			=> undef,
		@_
		);

	my $tool_config = $args{tool_config};
	my $data_config = $args{dna_config};
	my $rna_config = $args{rna_config};

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
	$log->autoflush;

	print $log "---\n";
	print $log "Running Mavis SV annotation pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n  Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n    Manta directory: $args{manta_dir}";
	print $log "\n    Delly directory: $args{delly_dir}";

	if (defined($args{starfusion_dir})) {
		print $log "\n  RNA sample config used: $rna_config";
		print $log "\n    STAR-Fusion directory: $args{starfusion_dir}";
		print $log "\n    FusionCatcher directory: $args{fusioncatcher_dir}";
		}

	print $log "\n---";

	# set tools and versions
	my $mavis	= 'mavis/' . $tool_data->{mavis_version};
	my $bwa		= 'bwa/' . $tool_data->{bwa_version};
	my $r_version	= 'R/' . $tool_data->{r_version};

	my $mavis_export = join("\n",
		"export MAVIS_ANNOTATIONS=$tool_data->{mavis}->{mavis_annotations}",
		"export MAVIS_MASKING=$tool_data->{mavis}->{mavis_masking}",
		"export MAVIS_DGV_ANNOTATION=$tool_data->{mavis}->{mavis_dgv_anno}",
		"export MAVIS_TEMPLATE_METADATA=$tool_data->{mavis}->{mavis_cytoband}",
		"export MAVIS_REFERENCE_GENOME=$tool_data->{reference}",
		"export MAVIS_ALIGNER='$tool_data->{mavis}->{mavis_aligner}'",
		"export MAVIS_ALIGNER_REFERENCE=$tool_data->{bwa}->{reference}",
		"export MAVIS_DRAW_FUSIONS_ONLY=True",
		"export MAVIS_SCHEDULER=" . uc($args{hpc_driver})
		);

	### RUN ###########################################################################################
	# get sample data
	my $smp_data = LoadFile($data_config);

	# find RNA samples (if provided)
	if (defined($rna_config)) {
		my $rna_data = LoadFile($rna_config);

		foreach my $patient (sort keys %{$smp_data}) {
			next if ( !any { /$patient/ } keys %{$rna_data});
			my @rna_ids = sort keys %{$rna_data->{$patient}->{'tumour'}};
			foreach my $id (@rna_ids) {
				my $bam = $rna_data->{$patient}->{'tumour'}->{$id};
				$smp_data->{$patient}->{'rna'}->{$id} = $bam;
				}
			}
		}

	# find SV files in each directory
	my (@manta_files, @delly_files, @starfusion_files, @fusioncatcher_files);
	if (defined($args{manta_dir})) {
		@manta_files = _get_files($args{manta_dir}, 'diploidSV.vcf.gz');
		push @manta_files, _get_files($args{manta_dir}, 'somaticSV.vcf.gz');
		push @manta_files, _get_files($args{manta_dir}, 'tumorSV.vcf.gz');
		}
	if (defined($args{delly_dir})) {
		@delly_files = _get_files($args{delly_dir}, 'Delly_SVs_somatic_hc.bcf');
		}
	if (defined($args{starfusion_dir})) {
		@starfusion_files = _get_files($args{starfusion_dir}, 'star-fusion.fusion_predictions.abridged.tsv');
		}
	if (defined($args{fusioncatcher_dir})) {
		@fusioncatcher_files = _get_files($args{fusioncatcher_dir}, 'final-list_candidate-fusion-genes.txt');
		}

	# initialize objects
	my ($run_script, $run_id, $link, $cleanup_cmd);
	my @all_jobs;

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient\n";

		# find bams
		my @normal_ids = sort keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = sort keys %{$smp_data->{$patient}->{'tumour'}};
		my @rna_ids_patient = sort keys %{$smp_data->{$patient}->{'rna'}};

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
		my $normal_id = $normal_ids[0];
		if (defined($normal_id)) {
			my @tmp = split /\//, $smp_data->{$patient}->{normal}->{$normal_id};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{normal}->{$normal_id}, $link);
			}

		# and format input files
		my (@manta_svs_formatted, @format_jobs);
		my (@delly_svs_patient, @starfus_svs_patient, @fuscatch_svs_patient);
		my $format_command;

		foreach my $tumour (@tumour_ids) {

			my @tmp = split /\//, $smp_data->{$patient}->{tumour}->{$tumour};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{tumour}->{$tumour}, $link);

			my @delly_svs = grep { /$tumour/ } @delly_files;
			$link = join('/', $link_directory, $tumour . '_Delly_SVs.bcf');
			symlink($delly_svs[0], $link);

			push @delly_svs_patient, $delly_svs[0];

			my @manta_svs = grep { /$tumour/ } @manta_files;
			foreach my $file ( @manta_svs ) {
				my @tmp = split /\//, $file;
				$link = join('/', $link_directory, $tumour . '_Manta_' . $tmp[-1]);
				symlink($file, $link);

				my $stem = $tmp[-1];
				$stem =~ s/.gz//;
				my $formatted_vcf = join('/', $patient_directory, $tumour . '_Manta_formatted_' . $stem);

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
			}

		foreach my $smp (@rna_ids_patient) {

			my @tmp = split /\//, $smp_data->{$patient}->{rna}->{$smp};
			$link = join('/', $link_directory, 'rna_' . $tmp[-1]);
			symlink($smp_data->{$patient}->{rna}->{$smp}, $link);

			my @starfus_svs = grep { /$smp/ } @starfusion_files;
			$link = join('/', $link_directory, $smp . '_star-fusion_predictions.abridged.tsv');
			symlink($starfus_svs[0], $link);

			push @starfus_svs_patient, $starfus_svs[0];

			my @fuscatch_svs = grep { /$smp/ } @fusioncatcher_files;

			$link = join('/', $link_directory, $smp . '_final-list_candidate-fusion-genes.txt');
			symlink($fuscatch_svs[0], $link);

			push @fuscatch_svs_patient, $fuscatch_svs[0];
			}

		# check if this should be run
		if ('Y' eq missing_file(@manta_svs_formatted)) {

			# record command (in log directory) and then run job
			print $log "Submitting job to format Manta SVs...\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_format_manta_svs_for_mavis_' . $patient,
				cmd	=> $format_command,
				modules	=> ['python/2.7'],
				hpc_driver	=> $args{hpc_driver}
				);

			$run_id = submit_job(
				jobname		=> 'run_format_manta_svs_for_mavis_' . $patient,
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
		my $mavis_cfg = join('/', $patient_directory, 'mavis.cfg');
		my $mavis_output = join('/',
			$patient_directory,
			'summary',
			'MAVIS*.COMPLETE'
			);

		my $memory = '4G';
		if (scalar(@rna_ids_patient) > 0) {

			$mavis_cmd .= "\n\necho 'Running mavis config.';\n\n" . get_mavis_command(
				tumour_ids	=> \@tumour_ids,
				normal_id	=> $normal_id,
				rna_ids		=> \@rna_ids_patient,
				tumour_bams	=> $smp_data->{$patient}->{tumour},
				normal_bam	=> $smp_data->{$patient}->{normal}->{$normal_id},
				rna_bams	=> $smp_data->{$patient}->{rna},
				manta		=> join(' ', @manta_svs_formatted),
				delly		=> join(' ', @delly_svs_patient),
				starfusion	=> join(' ', @starfus_svs_patient),
				fusioncatcher	=> join(' ', @fuscatch_svs_patient),
				output		=> $mavis_cfg
				);

			$memory = '8G';

			} else {

			$mavis_cmd .= "\n\necho 'Running mavis config.';\n\n" . get_mavis_command(
				tumour_ids	=> \@tumour_ids,
				normal_id	=> $normal_id,
				tumour_bams	=> $smp_data->{$patient}->{tumour},
				normal_bam	=> $smp_data->{$patient}->{normal}->{$normal_id},
				manta		=> join(' ', @manta_svs_formatted),
				delly		=> join(' ', @delly_svs_patient),
				output		=> $mavis_cfg
				);
			}

		$mavis_cmd .= "\n\necho 'Running mavis setup.';\n\nmavis setup $mavis_cfg -o $patient_directory";

		# if build.cfg already exists, then try resubmitting
		if ('Y' eq missing_file("$patient_directory/build.cfg")) {
			$mavis_cmd .= "\n\necho 'Running mavis schedule.';\n\nmavis schedule -o $patient_directory --submit";
			} else {
			$mavis_cmd =~ s/mavis config/#mavis config/;
			$mavis_cmd =~ s/mavis setup/#mavis setup/;
			$mavis_cmd .= "\n\necho 'Running mavis schedule with resubmit.';\n\nmavis schedule -o $patient_directory --resubmit";
			}

		$mavis_cmd .= "\n\necho 'MAVIS schedule complete, extracting job ids.';\n\n" . join(' ',
			"grep '^job_ident'",
			join('/', $patient_directory,  'build.cfg'),
			"| sed 's/job_ident = //' > ",
			join('/', $patient_directory, 'job_ids')
			);

		$mavis_cmd .= "\n\necho 'Beginning check of mavis jobs.';\n\n" . join(' ',
			"perl $cwd/mavis_check.pl",
			"-j", join('/', $patient_directory, 'job_ids')
			);

		# check if this should be run
		if ('Y' eq missing_file($mavis_output)) {

			# record command (in log directory) and then run job
			print $log "Submitting job for MAVIS SV annotator...\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_mavis_sv_annotator_' . $patient,
				cmd	=> $mavis_cmd,
				modules	=> [$mavis, $bwa, 'perl', 'R'],
				dependencies	=> join(':', @format_jobs),
				max_time	=> '12:00:00',
				mem		=> $memory,
				hpc_driver	=> $args{hpc_driver},
				kill_on_error	=> 0
				);

			$run_id = submit_job(
				jobname		=> 'run_mavis_sv_annotator_' . $patient,
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

		# should intermediate files be removed
		# run per patient
		if ($args{del_intermediates}) {

			print $log "Submitting job to clean up temporary/intermediate files...\n";

			# make sure final output exists before removing intermediate files!
			$cleanup_cmd = join("\n",
				"if [ -s $mavis_output ]; then",
				"  cd $patient_directory\n\n",
				"  find . -name '*.sam' -type f -exec rm {} " . '\;' . "\n",
				"  find . -name '*.bam' -type f -exec rm {} " . '\;' . "\n",
				"else",
				'  echo "FINAL OUTPUT FILE is missing; not removing intermediates"',
				"fi"
				);

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_cleanup_' . $patient,
				cmd	=> $cleanup_cmd,
				dependencies	=> $run_id,
				mem		=> '256M',
				hpc_driver	=> $args{hpc_driver},
				kill_on_error	=> 0
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

	# collate results
	my $collect_output = join(' ',
		"Rscript $cwd/collect_mavis_output.R",
		'-d', $output_directory,
		'-p', $tool_data->{project_name}
		);

	$run_script = write_script(
		log_dir	=> $log_directory,
		name	=> 'combine_variant_calls',
		cmd	=> $collect_output,
		modules	=> [$r_version],
		dependencies	=> join(':', @all_jobs),
		mem		=> '6G',
		max_time	=> '24:00:00',
		hpc_driver	=> $args{hpc_driver}
		);

	$run_id = submit_job(
		jobname		=> 'combine_variant_calls',
		shell_command	=> $run_script,
		hpc_driver	=> $args{hpc_driver},
		dry_run		=> $args{dry_run},
		log_file	=> $log
		);

	push @all_jobs, $run_id;

	# if this is not a dry run OR there are jobs to assess (run or resumed with jobs submitted) then
	# collect job metrics (exit status, mem, run time)
	unless ( ($args{dry_run}) || (scalar(@all_jobs) == 0) ) {

		# collect job stats
		my $collect_metrics = collect_job_stats(
			job_ids	=> join(',', @all_jobs),
			outfile	=> $outfile
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'output_job_metrics_' . $run_count,
			cmd	=> $collect_metrics,
			dependencies	=> join(':', @all_jobs),
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

		# wait until it finishes
		unless ($args{no_wait}) {

			my $complete = 0;
			my $timeouts = 0;

			while (!$complete && $timeouts < 20 ) {
				sleep(30);
				my $status = `sacct --format='State' -j $run_id`;

				# if final job has finished successfully:
				if ($status =~ m/COMPLETED/s) { $complete = 1; }
				# if we run into a server connection error (happens rarely with sacct)
				# increment timeouts (if we continue to repeatedly timeout, we will exit)
				elsif ($status =~ m/Connection timed out/) {
					$timeouts++;
					}
				# if the job is still pending or running, try again in a bit
				# but also reset timeouts, because we only care about consecutive timeouts
				elsif ($status =~ m/PENDING|RUNNING/) {
					$timeouts = 0;
					}
				# if none of the above, we will exit with an error
				else {
					die("Final MAVIS accounting job: $run_id finished with errors.");
					}
				}
			}
		}

	# finish up
	print $log "\nProgramming terminated successfully.\n\n";
	close $log;
	}

### GETOPTS AND DEFAULT VALUES #####################################################################
# declare variables
my ($tool_config, $data_config, $output_directory, $manta_directory, $delly_directory);
my ($rna_config, $starfusion_directory, $fusioncatcher_directory);
my $hpc_driver = 'slurm';
my ($remove_junk, $dry_run, $help, $no_wait);

# get command line arguments
GetOptions(
	'h|help'	=> \$help,
	'd|data=s'	=> \$data_config,
	'r|rna=s'	=> \$rna_config,
	't|tool=s'	=> \$tool_config,
	'o|out_dir=s'	=> \$output_directory,
	'm|manta=s'	=> \$manta_directory,
	'e|delly=s'	=> \$delly_directory,
	's|starfusion=s'	=> \$starfusion_directory,
	'f|fusioncatcher=s'	=> \$fusioncatcher_directory,
	'c|cluster=s'	=> \$hpc_driver,
	'remove'	=> \$remove_junk,
	'dry-run'	=> \$dry_run,
	'no-wait'	=> \$no_wait
	);

if ($help) {
	my $help_msg = join("\n",
		"Options:",
		"\t--help|-h\tPrint this help message",
		"\t--dna|-d\t<string> dna data config (yaml format)",
		"\t--rna|-r\t<string> rna data config (yaml format) <optional>",
		"\t--tool|-t\t<string> tool config (yaml format)",
		"\t--out_dir|-o\t<string> path to output directory",
		"\t--manta|-m\t<string> path to manta (strelka) output directory",
		"\t--delly|-e\t<string> path to delly output directory",
		"\t--starfusion|-s\t<string> path to star-fusion output directory <optional>",
		"\t--fusioncatcher|-f\t<string> path to fusioncatcher output directory <optional>",
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
if (!defined($manta_directory)) { die("No manta directory defined; please provide -m | --manta"); }
if (!defined($delly_directory)) { die("No delly directory defined; please provide -e | --delly"); }

main(
	tool_config		=> $tool_config,
	dna_config		=> $data_config,
	rna_config		=> $rna_config,
	output_directory	=> $output_directory,
	manta_dir		=> $manta_directory,
	delly_dir		=> $delly_directory,
	starfusion_dir		=> $starfusion_directory,
	fusioncatcher_dir	=> $fusioncatcher_directory,
	hpc_driver		=> $hpc_driver,
	del_intermediates	=> $remove_junk,
	dry_run			=> $dry_run,
	no_wait			=> $no_wait
	);
