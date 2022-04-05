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

my $cwd = dirname(__FILE__);
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
# format command to run Mavis
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
		novobreak	=> undef,
		svict		=> undef,
		pindel		=> undef,
		starfusion	=> undef,
		fusioncatcher	=> undef,
		output		=> undef,
		@_
		);

	my @dna_tools;
	my @rna_tools;

	my $mavis_cmd = join(' ',
		'mavis config',
		'-w', $args{output}
		);

	if (defined($args{delly})) {
		$mavis_cmd .= join(' ', ' --convert delly', $args{delly}, 'delly');
		push @dna_tools, 'delly';
		}

	if (defined($args{manta})) {
		$mavis_cmd .= join(' ', ' --convert manta', $args{manta}, 'manta');
		push @dna_tools, 'manta';
		}

	if (defined($args{novobreak})) {

		$mavis_cmd .= ' ' . join(' ',
			'--external_conversion novobreak "Rscript',
			"$cwd/convert_novobreak.R",
			$args{novobreak} . '"'
			);

		push @dna_tools, 'novobreak';
		}

	if (defined($args{svict})) {

		$mavis_cmd .= ' ' . join(' ',
			'--external_conversion svict "Rscript',
			"$cwd/convert_svict.R",
			$args{svict} . '"'
			);

		push @dna_tools, 'svict';
		}

	if (defined($args{pindel})) {

		$mavis_cmd .= ' ' . join(' ',
			'--external_conversion pindel "Rscript',
			"$cwd/convert_pindel.R",
			$args{pindel} . '"'
			);

		push @dna_tools, 'pindel';
		}

	if (defined($args{starfusion})) {
		$mavis_cmd .= ' ' . join(' ',
			'--convert starfusion', $args{starfusion}, 'starfusion'
			);

		push @rna_tools, 'starfusion';
		}

	if (defined($args{fusioncatcher})) {
		$mavis_cmd .= ' ' . join(' ',
			'--external_conversion fusioncatcher "Rscript',
			"$cwd/convert_fusioncatcher.R",
			$args{fusioncatcher} . '"'
			);

		push @rna_tools, 'fusioncatcher';
		}


	foreach my $smp ( @{$args{tumour_ids}} ) {

		my $id = $smp;
		if ($smp =~ m/^\d/) {
			$id = 'X' . $smp;
			}
		$id =~ s/_/-/g;

		$mavis_cmd .= ' ' . join(' ',
			'--library', $id, 'genome diseased False', $args{tumour_bams}->{$smp},
			'--assign', $id, join(' ', @dna_tools)
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
			'--assign', $id, join(' ', @dna_tools, @rna_tools)
			);
		}

	if (scalar(@{$args{rna_ids}}) > 0) {

		foreach my $smp ( @{$args{rna_ids}} ) {

			my $id = $smp;
			if ($smp =~ m/^\d/) {
				$id = 'X' . $smp;
				}
			$id =~ s/_/-/g;
			$id .= '-rna';

			$mavis_cmd .= ' ' . join(' ',
				'--library', $id, 'transcriptome diseased True', $args{rna_bams}->{$smp},
				'--assign', $id, join(' ', @rna_tools)
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
		novobreak_dir		=> undef,
		pindel_dir		=> undef,
		svict_dir		=> undef,
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
	unless($args{dry_run}) {
		print "Initiating MAVIS SV pipeline...\n";
		}

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

	if (defined($args{dna_config})) {
		print $log "\n  DNA sample config used: $data_config";

		if (defined($args{manta_dir})) {
			print $log "\n    Manta directory: $args{manta_dir}";
			}

		if (defined($args{delly_dir})) {
			print $log "\n    Delly directory: $args{delly_dir}";
			}

		if (defined($args{novobreak_dir})) {
			print $log "\n    NovoBreak directory: $args{novobreak_dir}";
			}

		if (defined($args{pindel_dir})) {
			print $log "\n    Pindel directory: $args{pindel_dir}";
			}

		if (defined($args{svict_dir})) {
			print $log "\n    SViCT directory: $args{svict_dir}";
			}
		}

	if (defined($rna_config)) {
		print $log "\n  RNA sample config used: $rna_config";

		if (defined($args{starfusion_dir})) {
			print $log "\n    STAR-Fusion directory: $args{starfusion_dir}";
			}

		if (defined($args{fusioncatcher_dir})) {
			print $log "\n    FusionCatcher directory: $args{fusioncatcher_dir}";
			}
		}

	my $intervals_bed;
	if (('targeted' eq $tool_data->{seq_type}) && (defined($tool_data->{intervals_bed}))) {
		$intervals_bed = $tool_data->{intervals_bed};
		$intervals_bed =~ s/\.bed/_padding100bp.bed/;
		print $log "\n  Filtering final output to target intervals: $intervals_bed";
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
		"export MAVIS_DRAW_FUSIONS_ONLY=$tool_data->{mavis}->{mavis_draw_fusions_only}",
		"export MAVIS_SCHEDULER=" . uc($args{hpc_driver})
		);

	if (defined($args{pindel_dir})) {
		$mavis_export .= "\n" . join("\n",
			"export MAVIS_MIN_CLUSTERS_PER_FILE=100",
			"export MAVIS_MAX_FILES=100"
			);
		}

	unless ('wgs' eq $tool_data->{seq_type}) {
		$mavis_export .= "\n" . "export MAVIS_UNINFORMATIVE_FILTER=True";
		}

	# get optional HPC group
	my $hpc_group = defined($tool_data->{hpc_group}) ? "-A $tool_data->{hpc_group}" : undef;

	# indicate memory to give for mavis
	my $mavis_memory = defined($tool_data->{mavis}->{mem}) ? $tool_data->{mavis}->{mem} : '4G';

	### RUN ###########################################################################################
	# get sample data
	my $smp_data;

	# find DNA samples (if provided)
	if (defined($data_config)) {
		my $dna_data = LoadFile($data_config);	

		foreach my $patient (sort keys %{$dna_data}) {
			my @normal_ids = sort keys %{$dna_data->{$patient}->{'normal'}};
			my @tumour_ids = sort keys %{$dna_data->{$patient}->{'tumour'}};

			foreach my $normal ( @normal_ids ) {
				my $bam = $dna_data->{$patient}->{'normal'}->{$normal};
				$smp_data->{$patient}->{'normal_dna'}->{$normal} = $bam;
				}
			foreach my $tumour ( @tumour_ids ) {
				my $bam = $dna_data->{$patient}->{'tumour'}->{$tumour};
				$smp_data->{$patient}->{'tumour_dna'}->{$tumour} = $bam;
				}
			}
		}

	# find RNA samples (if provided)
	if (defined($rna_config)) {
		my $rna_data = LoadFile($rna_config);

		foreach my $patient (sort keys %{$rna_data}) {
			my @rna_ids = sort keys %{$rna_data->{$patient}->{'tumour'}};
			foreach my $id ( @rna_ids ) {
				my $bam = $rna_data->{$patient}->{'tumour'}->{$id};
				$smp_data->{$patient}->{'tumour_rna'}->{$id} = $bam;
				}
			}
		}

	unless($args{dry_run}) {
		print "Processing " . scalar(keys %{$smp_data}) . " patients.\n";
		}

	# find SV files in each directory
	my (@manta_files, @delly_files, @starfusion_files, @fusioncatcher_files);
	my (@novobreak_files, @svict_files, @pindel_files);
	my $should_run_final;

	if (defined($args{manta_dir})) {
		@manta_files = _get_files($args{manta_dir}, 'diploidSV.vcf.gz');
		push @manta_files, _get_files($args{manta_dir}, 'somaticSV.vcf.gz');
		push @manta_files, _get_files($args{manta_dir}, 'tumorSV.vcf.gz');
		}
	if (defined($args{delly_dir})) {
		@delly_files = _get_files($args{delly_dir}, 'Delly_SVs_somatic_hc.bcf');
		}
	if (defined($args{novobreak_dir})) {
		@novobreak_files = _get_files($args{novobreak_dir}, 'novoBreak_filtered.tsv');
		}
	if (defined($args{pindel_dir})) {
		@pindel_files = _get_files($args{pindel_dir}, '_combined_Pindel_output.txt');
		push @pindel_files, _get_files($args{pindel_dir}, '_combined_Pindel_output.txt.gz');
		}
	if (defined($args{svict_dir})) {
		@svict_files = _get_files($args{svict_dir}, 'SViCT.vcf');
		}
	if (defined($args{starfusion_dir})) {
		@starfusion_files = _get_files($args{starfusion_dir}, 'star-fusion.fusion_predictions.abridged.tsv');
		}
	if (defined($args{fusioncatcher_dir})) {
		@fusioncatcher_files = _get_files($args{fusioncatcher_dir}, 'final-list_candidate-fusion-genes.txt');
		}

	# initialize objects
	my ($run_script, $run_id, $link, $cleanup_cmd);
	my (@delay_jobs, @all_jobs);

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		$run_id = '';

		print $log "\nInitiating process for PATIENT: $patient\n";

		# find bams
		my @normal_ids = sort keys %{$smp_data->{$patient}->{'normal_dna'}};
		my @tumour_ids = sort keys %{$smp_data->{$patient}->{'tumour_dna'}};
		my @rna_ids_patient = sort keys %{$smp_data->{$patient}->{'tumour_rna'}};

		print $log "> Found " . scalar(@normal_ids) . " normal BAMs.\n";
		print $log "> Found " . scalar(@tumour_ids) . " tumour BAMs.\n";
		print $log "> Found " . scalar(@rna_ids_patient) . " RNA-Seq BAMs.\n";

		if ( (scalar(@tumour_ids) == 0) & (scalar(@rna_ids_patient) == 0) ) {
			print $log "\n>> No tumour BAMs provided, skipping patient.\n";
			next;
			}

		# create some directories
		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my $link_directory = join('/', $patient_directory, 'input_links');
		unless(-e $link_directory) { make_path($link_directory); }

		# create some symlinks and add samples to sheet
		my $normal_id = undef;
		if (scalar(@normal_ids) > 0) {
			$normal_id = $normal_ids[0];
			my @tmp = split /\//, $smp_data->{$patient}->{'normal_dna'}->{$normal_id};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{'normal_dna'}->{$normal_id}, $link);
			}

		# and format input files
		my (@manta_svs_formatted, @format_jobs);
		my (@delly_svs_patient, @novobreak_svs_patient, @svict_svs_patient, @pindel_svs_patient);
		my (@starfus_svs_patient, @fuscatch_svs_patient);
		my $format_command;

		foreach my $normal (@normal_ids) {

			print $log ">> Finding files for NORMAL: $normal\n";

			# organize SViCT input
			if (scalar(@svict_files) > 0) {
				my @svict_svs = grep { /$normal/ } @svict_files;

				unless (scalar(@svict_svs) == 0) {
					$link = join('/', $link_directory, $normal . '_SViCT.vcf');
					symlink($svict_svs[0], $link);
					push @svict_svs_patient, $svict_svs[0];
					}
				}
			}

		foreach my $tumour (@tumour_ids) {

			print $log ">> Finding files for TUMOUR: $tumour\n";

			my @tmp = split /\//, $smp_data->{$patient}->{'tumour_dna'}->{$tumour};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{'tumour_dna'}->{$tumour}, $link);

			# organize Delly input
			if (scalar(@delly_files) > 0) {
				my @delly_svs = grep { /$tumour/ } @delly_files;

				unless (scalar(@delly_svs) == 0) {
					$link = join('/', $link_directory, $tumour . '_Delly_SVs.bcf');
					symlink($delly_svs[0], $link);
					push @delly_svs_patient, $delly_svs[0];
					}
				}

			# organize Manta input
			if (scalar(@manta_files)) {
				my @manta_svs = grep { /$tumour/ } @manta_files;
				foreach my $file ( @manta_svs ) {
					my @tmp = split /\//, $file;
					$link = join('/', $link_directory, $tumour . '_Manta_' . $tmp[-1]);
					symlink($file, $link);

					my $stem = $tmp[-1];
					$stem =~ s/.gz//;
					my $formatted_vcf = join('/',
						$patient_directory,
						$tumour . '_Manta_formatted_' . $stem
						);

					# write command to format manta SVs
					# (older version of Manta required for mavis)
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

			# organize NovoBreak input
			if (scalar(@novobreak_files) > 0) {
				my @novobreak_svs = grep { /$tumour/ } @novobreak_files;

				unless (scalar(@novobreak_svs) == 0) {
					$link = join('/', $link_directory, $tumour . '_NovoBreak.tsv');
					symlink($novobreak_svs[0], $link);
					push @novobreak_svs_patient, $novobreak_svs[0];
					}
				}

			# organize Pindel input
			if (scalar(@pindel_files) > 0) {
				my @pindel_svs = grep { /$tumour/ } @pindel_files;

				unless (scalar(@pindel_svs) == 0) {
					$link = join('/', $link_directory, $tumour . '_Pindel.txt');
					symlink($pindel_svs[0], $link);
					push @pindel_svs_patient, $pindel_svs[0];
					}
				}

			# organize SViCT input
			if (scalar(@svict_files) > 0) {
				my @svict_svs = grep { /$tumour/ } @svict_files;

				unless (scalar(@svict_svs) == 0) {
					$link = join('/', $link_directory, $tumour . '_SViCT.vcf');
					symlink($svict_svs[0], $link);
					push @svict_svs_patient, $svict_svs[0];
					}
				}
			}

		if (scalar(@tumour_ids) > 0) {
			print $log "> Found " . scalar(@manta_svs_formatted) . " manta files for $patient.\n";
			print $log "> Found " . scalar(@delly_svs_patient) . " delly files for $patient.\n";
			print $log "> Found " . scalar(@novobreak_svs_patient) . " novobreak files for $patient.\n";
			print $log "> Found " . scalar(@pindel_svs_patient) . " pindel files for $patient.\n";
			print $log "> Found " . scalar(@svict_svs_patient) . " svict files for $patient.\n";
			}

		foreach my $smp (@rna_ids_patient) {

			print $log ">> Finding files for RNA: $smp\n";

			my @tmp = split /\//, $smp_data->{$patient}->{'tumour_rna'}->{$smp};
			$link = join('/', $link_directory, 'rna_' . $tmp[-1]);
			symlink($smp_data->{$patient}->{'tumour_rna'}->{$smp}, $link);

			my @starfus_svs = grep { /$smp/ } @starfusion_files;
			$link = join('/', $link_directory, $smp . '_star-fusion_predictions.abridged.tsv');
			symlink($starfus_svs[0], $link);

			push @starfus_svs_patient, $starfus_svs[0];

			my @fuscatch_svs = grep { /$smp/ } @fusioncatcher_files;

			$link = join('/', $link_directory, $smp . '_final-list_candidate-fusion-genes.txt');
			symlink($fuscatch_svs[0], $link);

			push @fuscatch_svs_patient, $fuscatch_svs[0];
			}

		if (scalar(@rna_ids_patient) > 0) {
			print $log "> Found " . scalar(@starfus_svs_patient) . " starfusion files for $patient.\n";
			print $log "> Found " . scalar(@fuscatch_svs_patient) . " fusioncatcher files for $patient.\n";
			}

		# indicate expected mavis output file
		my $mavis_output = join('/',
			$patient_directory,
			'summary',
			'MAVIS*.COMPLETE'
			);

		my @is_mavis_complete = glob($mavis_output);

		# check if this should be run
		if ( ('Y' eq missing_file(@manta_svs_formatted)) && (!@is_mavis_complete) ) {

			# record command (in log directory) and then run job
			print $log "\nSubmitting job to format Manta SVs...\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_format_manta_svs_for_mavis_' . $patient,
				cmd	=> $format_command,
				modules	=> ['python/2.7'],
				hpc_driver	=> $args{hpc_driver},
				extra_args	=> [$hpc_group]
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
			} else {
			print $log "\nSkipping format manta step because this has already been completed!\n";
			}

		# now, run mavis (config, setup, schedule)
		my $mavis_cmd = $mavis_export;
		my $mavis_cfg = join('/', $patient_directory, 'mavis.cfg');

		my ($delly_input, $manta_input, $novobreak_input, $pindel_input, $svict_input) = undef;
		my ($starfus_input, $fuscatch_input) = undef;

		if (scalar(@delly_svs_patient) > 0) {
			$delly_input = join(' ', @delly_svs_patient);
			}
		if (scalar(@manta_svs_formatted) > 0) {
			$manta_input = join(' ', @manta_svs_formatted);
			}
		if (scalar(@novobreak_svs_patient) > 0) {
			$novobreak_input = join(' ', @novobreak_svs_patient);
			}
		if (scalar(@pindel_svs_patient) > 0) {
			$pindel_input = join(' ', @pindel_svs_patient);
			}
		if (scalar(@svict_svs_patient) > 0) {
			$svict_input = join(' ', @svict_svs_patient);
			}
		if (scalar(@starfus_svs_patient) > 0) {
			$starfus_input = join(' ', @starfus_svs_patient);
			}
		if (scalar(@fuscatch_svs_patient) > 0) {
			$fuscatch_input = join(' ', @fuscatch_svs_patient);
			}

		$mavis_cmd .= "\n\necho 'Running MAVIS config.';\n\n" . get_mavis_command(
			tumour_ids	=> \@tumour_ids,
			normal_id	=> $normal_id,
			rna_ids		=> \@rna_ids_patient,
			tumour_bams	=> $smp_data->{$patient}->{'tumour_dna'},
			normal_bam	=> defined($normal_id) ? $smp_data->{$patient}->{'normal_dna'}->{$normal_id} : undef,
			rna_bams	=> $smp_data->{$patient}->{'tumour_rna'},
			manta		=> $manta_input,
			delly		=> $delly_input,
			novobreak	=> $novobreak_input,
			pindel		=> $pindel_input,
			svict		=> $svict_input,
			starfusion	=> $starfus_input,
			fusioncatcher	=> $fuscatch_input,
			output		=> $mavis_cfg
			);

		$mavis_cmd .= "\n\necho 'Running MAVIS setup.';\n\n";
		$mavis_cmd .= "mavis setup $mavis_cfg -o $patient_directory";

		# if hpc_group is specified (not default)
		if (defined($hpc_group)) {

			my $add_group = join(' ',
				"find $patient_directory -name 'submit.sh' -exec",
				"sed -i '/^#!/a #SBATCH $hpc_group'" . ' {} \;'
				);

			$mavis_cmd .= "\n\n" . $add_group;
			}

		# if build.cfg already exists, then try resubmitting
		if ('Y' eq missing_file("$patient_directory/build.cfg")) {
			$mavis_cmd .= "\n\necho 'Running MAVIS schedule.';\n\n";
			$mavis_cmd .= "mavis schedule -o $patient_directory --submit";
			} else {
			$mavis_cmd =~ s/Running MAVIS config/MAVIS config already complete/;
			$mavis_cmd =~ s/mavis config/#mavis config/;
			$mavis_cmd =~ s/Running MAVIS setup/MAVIS setup already complete/;
			$mavis_cmd =~ s/mavis setup/#mavis setup/;
			$mavis_cmd =~ s/find/#find/;
			$mavis_cmd .= "\n\necho 'Running MAVIS schedule with resubmit.';\n\n";
			$mavis_cmd .= "mavis schedule -o $patient_directory --resubmit";
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

		$mavis_cmd .= "\n\n" . join("\n",
			"if [ ! -s $mavis_output ]; then",
			"  exit 1;",
			"fi"
			);

		# check if this should be run
		if (!@is_mavis_complete) {

			# record command (in log directory) and then run job
			print $log "Submitting job for MAVIS SV annotator...\n";

			my $dependencies = join(':', @format_jobs);
			if (scalar(@delay_jobs) >= 5) {
				my $current = scalar(@delay_jobs);
				my $start_point = $current - (5 + $current % 5);
				$dependencies = join(':',
					@format_jobs,
					@delay_jobs[$start_point..$start_point + 4]
					);
				}

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_mavis_sv_annotator_' . $patient,
				cmd	=> $mavis_cmd,
				modules	=> [$mavis, $bwa, 'perl', 'R'],
				dependencies	=> $dependencies,
				max_time	=> '5-00:00:00',
				mem		=> $mavis_memory,
				kill_on_error	=> 0,
				hpc_driver	=> $args{hpc_driver},
				extra_args	=> [$hpc_group]
				);

			$run_id = submit_job(
				jobname		=> 'run_mavis_sv_annotator_' . $patient,
				shell_command	=> $run_script,
				hpc_driver	=> $args{hpc_driver},
				dry_run		=> $args{dry_run},
				log_file	=> $log
				);

			push @delay_jobs, $run_id;
			push @all_jobs, $run_id;
			} else {
			print $log "Skipping MAVIS because this has already been completed!\n";
			}

		# if there are any samples to run, we will run the final combine job
		$should_run_final = 1;

		# collect key drawings
		my $get_drawings = join(' ',
			"Rscript $cwd/collect_mavis_output.R",
			'-d', $patient_directory,
			'--find_drawings TRUE'
			);

		# check if this should be run
		if ('Y' eq missing_file($patient_directory . '/key_drawings/find_drawings.COMPLETE')) {

			# record command (in log directory) and then run job
			print $log "Submitting job to extract gene-gene drawings...\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'extract_key_drawings_' . $patient,
				cmd	=> $get_drawings,
				modules	=> [$r_version],
				dependencies	=> $run_id,
				max_time	=> '10:00:00',
				hpc_driver	=> $args{hpc_driver},
				extra_args	=> [$hpc_group]
				);

			$run_id = submit_job(
				jobname		=> 'extract_key_drawings_' . $patient,
				shell_command	=> $run_script,
				hpc_driver	=> $args{hpc_driver},
				dry_run		=> $args{dry_run},
				log_file	=> $log
				);

			push @all_jobs, $run_id;
			} else {
			print $log "Skipping EXTRACT DRAWINGS because this has already been completed!\n";
			}

		# should intermediate files be removed
		# run per patient
		if ($args{del_intermediates}) {

			my $tar = 'tar -czvf intermediate_files.tar.gz pairing/ *_genome/';
			if (scalar(@rna_ids_patient) > 0) {
				$tar .= ' *_transcriptome/';
				}
			$tar .= ' --remove-files;';

			# make sure final output exists before removing intermediate files!
			$cleanup_cmd = join("\n",
				"if [ -s $mavis_output ]; then",
				"  cd $patient_directory\n",
				"  find . -name '*.sam' -type f -exec rm {} " . '\;',
				"  find . -name '*.bam' -type f -exec rm {} " . '\;',
				"  " . $tar,
				"else",
				'  echo "FINAL OUTPUT FILE is missing; not removing intermediates"',
				'  exit 1;',
				"fi"
				);

			if ('Y' eq missing_file($patient_directory . '/intermediate_files.tar.gz')) {

				print $log "Submitting job to clean up temporary/intermediate files...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_cleanup_' . $patient,
					cmd	=> $cleanup_cmd,
					dependencies	=> $run_id,
					max_time	=> '08:00:00',
					mem		=> '256M',
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_cleanup_' . $patient,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);
				} else {
				print $log "Skipping CLEANUP as this is already complete!\n";
				}
			}
		}

	# collate results
	if ($should_run_final) {

		my $collect_output = join(' ',
			"Rscript $cwd/collect_mavis_output.R",
			'-d', $output_directory,
			'-p', $tool_data->{project_name}
			);

		if (defined($intervals_bed)) {
			$collect_output .= " -t $intervals_bed";
			}

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'combine_variant_calls',
			cmd	=> $collect_output,
			modules	=> [$r_version],
			dependencies	=> join(':', @all_jobs),
			mem		=> '6G',
			max_time	=> '24:00:00',
			hpc_driver	=> $args{hpc_driver},
			extra_args	=> [$hpc_group]
			);

		$run_id = submit_job(
			jobname		=> 'combine_variant_calls',
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
my ($tool_config, $data_config, $output_directory, $manta_directory, $delly_directory);
my ($novobreak_directory, $pindel_directory, $svict_directory);
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
	'n|novobreak=s'	=> \$novobreak_directory,
	'p|pindel=s'	=> \$pindel_directory,
	'v|svict=s'	=> \$svict_directory,
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
		"\t--novobreak|-n\t<string> path to novobreak output directory",
		"\t--pindel|-p\t<string> path to pindel output directory",
		"\t--svict|-v\t<string> path to svict output directory",
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
if ( (!defined($data_config)) && (!defined($rna_config)) ) {
	die("No data config file defined; please provide -d | --data and/or -r | --rna (ie, sample_config.yaml)");
	}
if (!defined($output_directory)) { die("No output directory defined; please provide -o | --out_dir"); }

main(
	tool_config		=> $tool_config,
	dna_config		=> $data_config,
	rna_config		=> $rna_config,
	output_directory	=> $output_directory,
	manta_dir		=> $manta_directory,
	delly_dir		=> $delly_directory,
	svict_dir		=> $svict_directory,
	pindel_dir		=> $pindel_directory,
	novobreak_dir		=> $novobreak_directory,
	starfusion_dir		=> $starfusion_directory,
	fusioncatcher_dir	=> $fusioncatcher_directory,
	hpc_driver		=> $hpc_driver,
	del_intermediates	=> $remove_junk,
	dry_run			=> $dry_run,
	no_wait			=> $no_wait
	);
