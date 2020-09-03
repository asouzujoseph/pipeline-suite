#!/usr/bin/env perl
### strelka.pl #####################################################################################
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
use IO::Handle;

my $cwd = dirname($0);
require "$cwd/utilities.pl";

# define some global variables
our ($reference, $intervals, $seq_type, $pon) = undef;

####################################################################################################
# version       author		comment
# 1.0		sprokopec       script to run Strelka
# 1.1		sprokopec	added help msg and cleaned up code
# 1.2           sprokopec       minor updates for tool config

### USAGE ##########################################################################################
# strelka.pl -t tool_config.yaml -d data_config.yaml -o /path/to/output/dir -c slurm --remove --dry_run
#
# where:
#	-t (tool.yaml) contains tool versions and parameters, reference information, etc.
#	-d (data.yaml) contains sample information (YAML file containing paths to BWA-aligned,
#		GATK-processed BAMs, generated by gatk.pl)
#	-o (/path/to/output/dir) indicates tool-specific output directory
#	-c indicates hpc driver (ie, slurm)
#	--remove indicates that intermediates will be removed
#	--dry_run indicates that this is a dry run

### DEFINE SUBROUTINES #############################################################################
# format command to run Manta
sub get_manta_command {
	my %args = (
		tumour		=> undef,
		normal		=> undef,
		output_dir	=> undef,
		intervals	=> undef,
		tmp_dir		=> undef,
		@_
		);

	my $manta_cmd;

	if (defined($args{normal})) {
		$manta_cmd = join(' ',
			'configManta.py',
			'--normalBam', $args{normal},
			'--tumorBam', $args{tumour},
			'--referenceFasta', $reference,
			'--runDir', $args{output_dir}
			);
		} else {
		$manta_cmd = join(' ',
			'configManta.py',
			'--tumorBam', $args{tumour},
			'--referenceFasta', $reference,
			'--runDir', $args{output_dir}
			);
		}

	if (('exome' eq $seq_type) || ('targeted' eq $seq_type)) {
		$manta_cmd .= " --exome --callRegions $args{intervals}";
		} elsif ( ('rna' eq $seq_type) && (!defined($args{normal})) ) {
		$manta_cmd .= " --rna";
		}
	
	return($manta_cmd);
	}

# format command to run Strelka Somatic Workflow
sub get_strelka_somatic_command {
	my %args = (
		tumour		=> undef,
		normal		=> undef,
		indels		=> undef,
		intervals	=> undef,
		out_dir		=> undef,
		tmp_dir		=> undef,
		@_
		);

	my $strelka_cmd = join(' ',
		'configureStrelkaSomaticWorkflow.py',
		'--normalBam', $args{normal},
		'--tumourBam', $args{tumour},
		'--referenceFasta', $reference,
		'--indelCandidates', $args{indels},
		'--runDir', $args{out_dir}
		);

	if ('exome' eq $seq_type) {
		$strelka_cmd .= " --exome";
		} elsif ('targeted' eq $seq_type) {
		$strelka_cmd .= " --targeted";
		}

	if (defined($args{intervals})) {
		$strelka_cmd .= " --callRegions $args{intervals}";
		}

	return($strelka_cmd);
	}

# format command to run Strelka Germline Workflow
sub get_strelka_germline_command {
	my %args = (
		input		=> undef,
		intervals	=> undef,
		out_dir		=> undef,
		tmp_dir		=> undef,
		@_
		);

	my $strelka_cmd = join(' ',
		'configureStrelkaGermlineWorkflow.py',
		'--bam', $args{input},
		'--referenceFasta', $reference,
		'--runDir', $args{out_dir}
		);

	if ('exome' eq $seq_type) {
		$strelka_cmd .= " --exome";
		} elsif ('targeted' eq $seq_type) {
		$strelka_cmd .= " --targeted";
		} elsif ('rna' eq $seq_type) {
		$strelka_cmd .= " --rna";
		}

	if (defined($args{intervals})) {
		$strelka_cmd .= " --callRegions $args{intervals}";
		}

	return($strelka_cmd);
	}

# format command to filter results
sub get_filter_command {
	my %args = (
		input	=> undef,
		output	=> undef,
		pon	=> undef,
		tmp_dir	=> undef,
		split	=> 0,
		@_
		);

	my $filter_command;

	# if this is tumour-only (and somatic), split indels and snps
	if ($args{split}) {

		$filter_command = join(' ',
			'vcftools',
			'--gzvcf', $args{input},
			'--stdout --recode',
			'--keep-filtered PASS --remove-indels',
			'--temp', $args{tmp_dir}
			);

		if (defined($args{pon})) {
			$filter_command .= " --exclude-positions $args{pon}";
			}

		$filter_command .= " > $args{output}\_snvs_filtered.vcf";

		$filter_command .= "\n\n" . join(' ',
			'vcftools',
			'--gzvcf', $args{input},
			'--stdout --recode',
			'--keep-filtered PASS --keep-only-indels',
			'--temp', $args{tmp_dir}
			);

		if (defined($args{pon})) {
			$filter_command .= " --exclude-positions $args{pon}";
			}

		$filter_command .= " > $args{output}\_indels_filtered.vcf";

		} else {

		$filter_command = join(' ',
			'vcftools',
			'--gzvcf', $args{input},
			'--stdout --recode',
			'--keep-filtered PASS',
			'--temp', $args{tmp_dir}
			);

		if (defined($args{pon})) {
			$filter_command .= " --exclude-positions $args{pon}";
			}

		$filter_command .= " > $args{output}";
		}

	return($filter_command);
	}

# format command to generate PON
sub  generate_pon {
	my %args = (
		input		=> undef,
		output		=> undef,
		java_mem	=> undef,
		tmp_dir		=> undef,
		out_type	=> 'full',
		@_
		);

	my $pon_command = join(' ',
		'java -Xmx' . $args{java_mem},
		'-Djava.io.tmpdir=' . $args{tmp_dir},
		'-jar $gatk_dir/GenomeAnalysisTK.jar -T CombineVariants',
		'-R', $reference,
		$args{input},
		'-o', $args{output},
		'--filteredrecordsmergetype KEEP_IF_ANY_UNFILTERED',
		'--genotypemergeoption UNSORTED --filteredAreUncalled'
		);

	if ('trimmed' eq $args{out_type}) {
		$pon_command .= ' -minN 2 -minimalVCF -suppressCommandLineHeader --excludeNonVariants --sites_only';
		}

	return($pon_command);
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

	# load tool config
	my $tool_data_orig = LoadFile($tool_config);
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'strelka');
	my $date = strftime "%F", localtime;

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_STRELKA_pipeline.log');

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

		$log_file = join('/', $log_directory, 'run_STRELKA_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";
	$log->autoflush;

	print $log "---\n";
	print $log "Running Strelka variant calling pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Reference used: $tool_data->{reference}";

	$reference = $tool_data->{reference};
	$seq_type = $tool_data->{seq_type};

	if (defined($tool_data->{intervals_bed})) {
		$intervals = $tool_data->{intervals_bed};
		print $log "\n    Target intervals: $intervals";
		}

	if (defined($args{pon})) {
		print $log "\n    Panel of Normals: $args{pon}";
		$pon = $args{pon};
		}

	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---";

	# set tools and versions
	my $strelka	= 'strelka/' . $tool_data->{strelka_version};
	my $manta	= 'manta/' . $tool_data->{manta_version};
	my $vcftools	= 'vcftools/' . $tool_data->{vcftools_version};
	my $samtools	= 'samtools/' . $tool_data->{samtools_version};
	my $gatk	= 'gatk/' . $tool_data->{gatk_version};
	my $r_version	= 'R/' . $tool_data->{r_version};

	# get user-specified tool parameters
	my $parameters = $tool_data->{strelka}->{parameters};

	### RUN ###########################################################################################
	my ($run_script, $run_id, $link);
	my (@all_jobs, @all_pon_jobs, @pon_vcfs);
	my $interval_run_id = '';

	# first, intervals file must be bgzipped and tabix indexed
	if ($intervals !~ m/gz$/) {

		my $old_intervals = $intervals;
		my @parts = split(/\//, $old_intervals);
		$intervals = join('/',
			$output_directory,
			$parts[-1]
			);

		if ( (-l $intervals) && ('Y' eq missing_file("$intervals.gz"))) {
			unlink $intervals or die "Failed to remove previous symlink: $intervals";
			}

		symlink($old_intervals, $intervals);

		if ('Y' eq missing_file("$intervals.gz")) {
			my $format_intervals_command = "bgzip -c $intervals > $intervals.gz";
			$format_intervals_command .= "\ntabix -p bed $intervals.gz";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_format_intervals_bed',
				cmd	=> $format_intervals_command,
				modules	=> ['tabix'],
				hpc_driver	=> $args{hpc_driver}
				);

			$interval_run_id = submit_job(
				jobname		=> 'run_format_intervals_bed',
				shell_command	=> $run_script,
				hpc_driver	=> $args{hpc_driver},
				dry_run		=> $args{dry_run},
				log_file	=> $log
				);
			}

		$intervals .= '.gz';
		}

	# get sample data
	my $smp_data = LoadFile($data_config);

	# create an array to hold final outputs and all patient job ids
	my (%final_outputs, %patient_jobs, %cleanup);

	# process each sample in $smp_data
	print $log "\nCreating directory structure and running germline variant caller...\n";

	foreach my $patient (sort keys %{$smp_data}) {

		# find bams
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};

		# create some directories
		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my $tmp_directory = join('/', $patient_directory, 'TEMP');
		unless(-e $tmp_directory) { make_path($tmp_directory); }

		my $link_directory = join('/', $patient_directory, 'bam_links');
		unless(-e $link_directory) { make_path($link_directory); }

		# create some symlinks
		foreach my $normal (@normal_ids) {
			my @tmp = split /\//, $smp_data->{$patient}->{normal}->{$normal};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{normal}->{$normal}, $link);
			}
		foreach my $tumour (@tumour_ids) {
			my @tmp = split /\//, $smp_data->{$patient}->{tumour}->{$tumour};
			$link = join('/', $link_directory, $tmp[-1]);
			symlink($smp_data->{$patient}->{tumour}->{$tumour}, $link);
			}

		@patient_jobs{$patient} = [];
		@final_outputs{$patient} = [];
		$cleanup{$patient} = "rm -rf $tmp_directory";

		next if (scalar(@normal_ids) == 0);
		next if ('rna' eq $seq_type);

		# for germline variants
		foreach my $norm (@normal_ids) {

			print $log "\n>>NORMAL: $norm\n";

			my $germline_directory = join('/', $patient_directory, $norm);
			unless(-e $germline_directory) { make_path($germline_directory); }

			$run_id = $interval_run_id;

			# run germline snv caller
			my $germline_snv_command = get_strelka_germline_command(
				input		=> $smp_data->{$patient}->{normal}->{$norm},
				out_dir		=> $germline_directory,
				tmp_dir		=> $tmp_directory,
				intervals	=> $intervals
				);

			$germline_snv_command .= ";\n\n$germline_directory/runWorkflow.py --quiet -m local";

			my $germline_output = join('/', $germline_directory, 'results','variants','variants.vcf.gz');

			$cleanup{$patient} .= "\nrm -rf " . join('/', $germline_directory, 'workspace');
			$cleanup{$patient} .= "\nrm -rf " . join('/', $germline_directory, 'results');

			# indicate output from next step
			my $filtered_germline_output = join('/',
				$germline_directory,
				$norm . '_Strelka_germline_filtered.vcf'
				);

			# check if this should be run
			if (
				('Y' eq missing_file($germline_output)) && 
				('Y' eq missing_file($filtered_germline_output)) 
				) {

				# record command (in log directory) and then run job
				print $log "Submitting job for Strelka (germline)...\n";

				# if this has been run once before and failed, we need to clean up the previous attempt
				# before initiating a new one
				if ('N' eq missing_file("$germline_directory/runWorkflow.py")) {
					`rm -rf $germline_directory`;
					}

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_strelka_germline_variant_caller_' . $norm,
					cmd	=> $germline_snv_command,
					modules	=> [$strelka],
					max_time	=> $parameters->{strelka}->{time},
					mem		=> $parameters->{strelka}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_strelka_germline_variant_caller_' . $norm,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @{$patient_jobs{$patient}}, $run_id;
				push @all_pon_jobs, $run_id;
				}
			else {
				print $log "Skipping Strelka (germline) because this has already been completed!\n";
				}

			# filter results to keep only confident (PASS) calls
			my $filter_command = get_filter_command(
				input	=> $germline_output,
				output	=> $filtered_germline_output,
				tmp_dir	=> $tmp_directory
				);

			$filter_command .= "\n\nmd5sum $filtered_germline_output > $filtered_germline_output.md5";

			# check if this should be run
			if ('Y' eq missing_file($filtered_germline_output . '.md5')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for VCF-Filter (germline)...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_vcf_filter_germline_variants_' . $norm,
					cmd	=> $filter_command,
					modules	=> [$vcftools],
					dependencies	=> $run_id,
					max_time	=> $parameters->{filter}->{time},
					mem		=> $parameters->{filter}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_vcf_filter_germline_variants_' . $norm,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @{$patient_jobs{$patient}}, $run_id;
				push @all_pon_jobs, $run_id;

				}
			else {
				print $log "Skipping VCF-Filter (germline) because this has already been completed!\n";
				}

			push @pon_vcfs, "-V:$norm $filtered_germline_output";
			}
		}

	push @all_jobs, @all_pon_jobs;

	# should the panel of normals be created?
	my $pon_run_id = '';

	unless (
		(defined($pon)) && (-s $pon) ||
		('rna' eq $seq_type)
		) {

		print $log "\nCreating panel of normals...\n";

		# let's create a command and write script to combine variants for a PoN
		my $pon_directory = join('/', $output_directory, 'PanelOfNormals');
		unless(-e $pon_directory) { make_path($pon_directory); }

		my $pon_tmp	= join('/', $pon_directory, $date . "_merged_panelOfNormals.vcf");
		$pon		= join('/', $pon_directory, $date . "_merged_panelOfNormals_trimmed.vcf");
		my $final_pon_link = join('/', $output_directory, 'panel_of_normals.vcf');

		# create a trimmed (sites only) output (this is the panel of normals)
		my $pon_command = generate_pon(
			input		=> join(' ', @pon_vcfs),
			output		=> $pon,
			java_mem	=> $parameters->{combine}->{java_mem},
			tmp_dir		=> $pon_directory,
			out_type	=> 'trimmed'
			);

		if (-l $final_pon_link) {
			unlink $final_pon_link or die "Failed to remove previous symlink: $final_pon_link";
			}

		symlink($pon, $final_pon_link);

		$pon_command .= "\n" . check_java_output(
			extra_cmd => "  md5sum $pon > $pon.md5"
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'create_sitesOnly_trimmed_panel_of_normals',
			cmd	=> $pon_command,
			modules	=> [$gatk],
			dependencies	=> join(':', @all_pon_jobs),
			max_time	=> $parameters->{combine}->{time},
			mem		=> $parameters->{combine}->{mem},
			hpc_driver	=> $args{hpc_driver}
			);

		$pon_run_id = submit_job(
			jobname		=> 'create_sitesOnly_trimmed_panel_of_normals',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $pon_run_id;

		# create a fully merged output (useful for combining with other studies later)
		$pon_command = generate_pon(
			input		=> join(' ', @pon_vcfs),
			output		=> $pon_tmp,
			java_mem	=> $parameters->{combine}->{java_mem},
			tmp_dir		=> $pon_directory,
			out_type	=> 'full'
			);

		$pon_command .= "\n" . check_java_output(
			extra_cmd => "md5sum $pon_tmp > $pon_tmp.md5;\n  bgzip $pon_tmp;\n  tabix -p vcf $pon_tmp.gz;"
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'create_panel_of_normals',
			cmd	=> $pon_command,
			dependencies	=> join(':', @all_pon_jobs, $pon_run_id),
			modules		=> [$gatk, 'tabix'],
			max_time	=> $parameters->{combine}->{time},
			mem		=> $parameters->{combine}->{mem},
			hpc_driver	=> $args{hpc_driver}
			);

		$run_id = submit_job(
			jobname		=> 'create_panel_of_normals',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);

		push @all_jobs, $run_id;
		}

	# loop over all samples again, this time to run somatic callers
	print $log "\nRunning manta and somatic variant caller...\n\n";

	foreach my $patient (sort keys %{$smp_data}) {

		# find bams
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};

		next if (scalar(@tumour_ids) == 0);

		# create some directories
		my $patient_directory = join('/', $output_directory, $patient);
		my $tmp_directory = join('/', $patient_directory, 'TEMP');

		# for T/N pair
		foreach my $sample (@tumour_ids) {

			print $log ">>TUMOUR: $sample\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			$run_id = '';

			# first, run MANTA to find small indels
			my $manta_directory = join('/', $sample_directory, 'Manta');
			unless(-e $manta_directory) { make_path($manta_directory); }

			my $manta_command;

			# run on tumour-only (includes RNA)
			if (scalar(@normal_ids) == 0) {

				$manta_command = get_manta_command(
					tumour		=> $smp_data->{$patient}->{tumour}->{$sample},
					output_dir	=> $manta_directory,
					intervals	=> $intervals,
					tmp_dir		=> $tmp_directory
					);

				} else { # run on T/N pairs

				$manta_command = get_manta_command(
					tumour		=> $smp_data->{$patient}->{tumour}->{$sample},
					normal		=> $smp_data->{$patient}->{normal}->{$normal_ids[0]},
					output_dir	=> $manta_directory,
					intervals	=> $intervals,
					tmp_dir		=> $tmp_directory
					);
				}

			$manta_command .= ";\n\n$manta_directory/runWorkflow.py --quiet";

			my $manta_output = join('/', $manta_directory, 'results/variants/candidateSmallIndels.vcf.gz');

			$cleanup{$patient} .= "\nrm -rf " . join('/', $manta_directory, 'workspace');

			my $manta_run_id = '';

			# check if this should be run
			if ('Y' eq missing_file($manta_output)) {

				# record command (in log directory) and then run job
				print $log "Submitting job for Manta...\n";

				# if this has been run once before and failed, we need to clean up the previous attempt
				# before initiating a new one
				if ('N' eq missing_file("$manta_directory/runWorkflow.py")) {
					`rm -rf $manta_directory`;
					}

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_manta_' . $sample,
					cmd	=> $manta_command,
					modules	=> [$manta],
					max_time	=> $parameters->{manta}->{time},
					mem		=> $parameters->{manta}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$manta_run_id = submit_job(
					jobname		=> 'run_manta_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @{$patient_jobs{$patient}}, $manta_run_id;
				}
			else {
				print $log "Skipping MANTA because this has already been completed!\n";
				}

			push @{$final_outputs{$patient}}, $manta_output;

			# next, run Strelka Somatic variant caller (T/N only)
			my $somatic_snv_command;

			# run on T/N pairs
			if (scalar(@normal_ids) > 0) {

				$somatic_snv_command = get_strelka_somatic_command(
					tumour		=> $smp_data->{$patient}->{tumour}->{$sample},
					normal		=> $smp_data->{$patient}->{normal}->{$normal_ids[0]},
					out_dir		=> $sample_directory,
					tmp_dir		=> $tmp_directory,
					intervals	=> $intervals,
					indels		=> $manta_output
					);

				} else {

				# run germline snv caller using tumour-only bam as input (includes RNA)
				$somatic_snv_command = get_strelka_germline_command(
					input		=> $smp_data->{$patient}->{tumour}->{$sample},
					out_dir		=> $sample_directory,
					tmp_dir		=> $tmp_directory,
					intervals	=> $intervals
					);
				}

			$somatic_snv_command .= ";\n\n$sample_directory/runWorkflow.py --quiet -m local";

			my $somatic_snv_output   = join('/', $sample_directory, 'results/variants/somatic.snvs.vcf.gz');
			my $somatic_indel_output = join('/', $sample_directory, 'results/variants/somatic.indels.vcf.gz');
			my $somatic_tonly_output = join('/', $sample_directory, 'results/variants/variants.vcf.gz');

			$cleanup{$patient} .= "\nrm -rf " . join('/', $sample_directory, 'workspace');
			$cleanup{$patient} .= "\nrm -rf " . join('/', $sample_directory, 'results');


			# filter variant calls
			my ($filter_command, $required, $depends);
			my ($filtered_output, $filtered_indels, $filtered_snvs);

			if ('rna' eq $seq_type) {

				# filter results to keep confident calls (PASS)
				$filtered_output = join('/',
					$sample_directory,
					$sample . '_Strelka_somatic_filtered.vcf'
					);

				$filter_command = get_filter_command(
					input	=> $somatic_tonly_output,
					output	=> $filtered_output,
					tmp_dir	=> $tmp_directory
					);

				$filter_command .= "\n\nmd5sum $filtered_output > $filtered_output.md5";

				$required = $filtered_output;
				$depends  = $run_id;

				} elsif (scalar(@normal_ids) == 0) {

				# filter results to keep confident calls (PASS)
				# and split into snv/indel
				$filtered_output = join('/',
					$sample_directory,
					$sample . '_Strelka_somatic'
					);

				$filtered_snvs = $filtered_output . '_snvs_filtered.vcf';
				$filtered_indels = $filtered_output . '_indels_filtered.vcf';

				$filter_command = get_filter_command(
					input	=> $somatic_tonly_output,
					output	=> $filtered_output,
					pon	=> $pon,
					tmp_dir	=> $tmp_directory,
					split	=> 1
					);

				$filter_command .= "\n\nmd5sum $filtered_snvs > $filtered_snvs.md5";
				$filter_command .= "\n\nmd5sum $filtered_indels > $filtered_indels.md5";

				$required = $filtered_indels;
				$depends  = join(':', $run_id, $pon_run_id, $manta_run_id);

				} else {

				# filter results using PoN and keep confident calls (PASS)
				$filtered_snvs = join('/',
					$sample_directory,
					$sample . '_Strelka_somatic_snvs_filtered.vcf'
					);

				$filter_command = get_filter_command(
					input	=> $somatic_snv_output,
					output	=> $filtered_snvs,
					pon	=> $pon,
					tmp_dir	=> $tmp_directory
					);

				$filter_command .= "\n\nmd5sum $filtered_snvs > $filtered_snvs.md5";

				$filtered_indels = join('/',
					$sample_directory,
					$sample . '_Strelka_somatic_indels_filtered.vcf'
					);

				$filter_command .= "\n\n" . get_filter_command(
					input	=> $somatic_indel_output,
					output	=> $filtered_indels,
					pon	=> $pon,
					tmp_dir	=> $tmp_directory
					);

				$filter_command .= "\n\nmd5sum $filtered_indels > $filtered_indels.md5";

				$required = $filtered_indels;
				$depends  = join(':', $run_id, $pon_run_id, $manta_run_id);
				}

			my $strelka_run_id = '';

			# if filter output already exists, don't re-run strelka caller
			if (
				('Y' eq missing_file($somatic_indel_output)) &&
				('Y' eq missing_file($somatic_tonly_output)) &&
				('Y' eq missing_file("$required.md5"))
				) {

				# record command (in log directory) and then run job
				print $log "Submitting job for Strelka (somatic)...\n";

				# if this has been run once before and failed, we need to clean up the previous attempt
				# before initiating a new one
				if ('N' eq missing_file("$sample_directory/runWorkflow.py")) {
					`rm -rf $sample_directory/results/`;
					`rm -rf $sample_directory/workspace/`;
					`rm $sample_directory/workflow*`;
					`rm $sample_directory/runWorkflow*`;
					}

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_strelka_somatic_variant_caller_' . $sample,
					cmd	=> $somatic_snv_command,
					modules	=> [$strelka],
					dependencies	=> join(':', $run_id, $manta_run_id),
					max_time	=> $parameters->{strelka}->{time},
					mem		=> $parameters->{strelka}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$strelka_run_id = submit_job(
					jobname		=> 'run_strelka_somatic_variant_caller_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @{$patient_jobs{$patient}}, $strelka_run_id;
				}
			else {
				print $log "Skipping Strelka (somatic) because this has already been completed!\n";
				}

			my $filter_run_id = '';

			# check if this should be run
			if ('Y' eq missing_file($required . '.md5')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for VCF-Filter (somatic)...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_vcf_filter_somatic_variants_' . $sample,
					cmd	=> $filter_command,
					modules	=> [$vcftools],
					dependencies	=> join(':', $depends, $strelka_run_id),
					max_time	=> $parameters->{filter}->{time},
					mem		=> $parameters->{filter}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$filter_run_id = submit_job(
					jobname		=> 'run_vcf_filter_somatic_variants_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @{$patient_jobs{$patient}}, $filter_run_id;
				}
			else {
				print $log "Skipping VCF-Filter (somatic) because this has already been completed!\n";
				}

			### Run variant annotation (VEP + vcf2maf)
			my ($final_maf, $final_vcf, $vcf2maf_cmd, $annotate_run_id);

			my $normal_id = undef;
			if (scalar(@normal_ids) > 0) { $normal_id = $normal_ids[0]; }

			# annotate INDELS
			$final_maf = join('/', $sample_directory, $sample . '_somatic_indels_annotated.maf');
			$final_vcf = join('/', $sample_directory, $sample . '_somatic_indels_annotated.vcf');

			$vcf2maf_cmd = get_vcf2maf_command(
				input		=> $filtered_indels,
				tumour_id	=> $sample,
				normal_id	=> $normal_id,
				reference	=> $reference,
				ref_type	=> $tool_data->{ref_type},
				output		=> $final_maf,
				tmp_dir		=> $tmp_directory,
				vcf2maf		=> $tool_data->{annotate}->{vcf2maf_path},
				vep_path	=> $tool_data->{annotate}->{vep_path},
				vep_data	=> $tool_data->{annotate}->{vep_data},
				filter_vcf	=> $tool_data->{annotate}->{filter_vcf}
				);

			# check if this should be run
			if ('Y' eq missing_file($final_maf . '.md5')) {

				if ('N' eq missing_file("$tmp_directory/$sample\_Strelka_somatic_indels_filtered.vep.vcf")) {
					`rm $tmp_directory/$sample\_Strelka_somatic_indels_filtered.vep.vcf`;
					}

				# IF THIS FINAL STEP IS SUCCESSFULLY RUN
				$vcf2maf_cmd .= "\n\n" . join("\n",
					"if [ -s " . join(" ] && [ -s ", $final_maf) . " ]; then",
					"  md5sum $final_maf > $final_maf.md5",
					"  mv $tmp_directory/$sample\_Strelka_somatic_indels_filtered.vep.vcf $final_vcf",
					"  md5sum $final_vcf > $final_vcf.md5",
					"  bgzip $final_vcf",
					"  tabix -p vcf $final_vcf.gz",
					"else",
					'  echo "FINAL OUTPUT MAF is missing; not running md5sum/bgzip/tabix..."',
					"fi"
					);

				# record command (in log directory) and then run job
				print $log "Submitting job for VEP + vcf2maf (indels)...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_VEP_and_vcf2maf_indels_' . $sample,
					cmd	=> $vcf2maf_cmd,
					modules	=> ['perl', $samtools, 'tabix'],
					dependencies	=> $filter_run_id,
					max_time	=> $tool_data->{annotate}->{time},
					mem		=> $tool_data->{annotate}->{mem}->{indels},
					hpc_driver	=> $args{hpc_driver}
					);

				$annotate_run_id = submit_job(
					jobname		=> 'run_VEP_and_vcf2maf_indels' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @{$patient_jobs{$patient}}, $annotate_run_id;
				}
			else {
				print $log "Skipping vcf2maf (indels) because this has already been completed!\n";
				}

			push @{$final_outputs{$patient}}, $final_maf;

			# annotate SNVs
			$final_maf = join('/', $sample_directory, $sample . '_somatic_snvs_annotated.maf');
			$final_vcf = join('/', $sample_directory, $sample . '_somatic_snvs_annotated.vcf');

			$vcf2maf_cmd = get_vcf2maf_command(
				input		=> $filtered_snvs,
				tumour_id	=> $sample,
				normal_id	=> $normal_id,
				reference	=> $reference,
				ref_type	=> $tool_data->{ref_type},
				output		=> $final_maf,
				tmp_dir		=> $tmp_directory,
				vcf2maf		=> $tool_data->{annotate}->{vcf2maf_path},
				vep_path	=> $tool_data->{annotate}->{vep_path},
				vep_data	=> $tool_data->{annotate}->{vep_data},
				filter_vcf	=> $tool_data->{annotate}->{filter_vcf}
				);

			# check if this should be run
			if ('Y' eq missing_file($final_maf . '.md5')) {

				if ('N' eq missing_file("$tmp_directory/$sample\_Strelka_somatic_snvs_filtered.vep.vcf")) {
					`rm $tmp_directory/$sample\_Strelka_somatic_snvs_filtered.vep.vcf`;
					}

				# IF THIS FINAL STEP IS SUCCESSFULLY RUN
				$vcf2maf_cmd .= "\n\n" . join("\n",
					"if [ -s " . join(" ] && [ -s ", $final_maf) . " ]; then",
					"  md5sum $final_maf > $final_maf.md5",
					"  mv $tmp_directory/$sample\_Strelka_somatic_snvs_filtered.vep.vcf $final_vcf",
					"  md5sum $final_vcf > $final_vcf.md5",
					"  bgzip $final_vcf",
					"  tabix -p vcf $final_vcf.gz",
					"else",
					'  echo "FINAL OUTPUT MAF is missing; not running md5sum/bgzip/tabix..."',
					"fi"
					);

				# record command (in log directory) and then run job
				print $log "Submitting job for VEP + vcf2maf (SNVs)...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_VEP_and_vcf2maf_snvs_' . $sample,
					cmd	=> $vcf2maf_cmd,
					modules	=> ['perl', $samtools, 'tabix'],
					dependencies	=> $filter_run_id,
					max_time	=> $tool_data->{annotate}->{time},
					mem		=> $tool_data->{annotate}->{mem}->{snps},
					hpc_driver	=> $args{hpc_driver}
					);

				$annotate_run_id = submit_job(
					jobname		=> 'run_VEP_and_vcf2maf_snvs' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @{$patient_jobs{$patient}}, $annotate_run_id;
				}
			else {
				print $log "Skipping vcf2maf (snvs) because this has already been completed!\n";
				}

			push @{$final_outputs{$patient}}, $final_maf;

			}

		if (scalar(@{$patient_jobs{$patient}}) > 0) { push @all_jobs, @{$patient_jobs{$patient}}; }

		# should intermediate files be removed
		# run per patient
		if ($args{del_intermediates}) {

			if (scalar(@{$patient_jobs{$patient}}) == 0) {
				`rm -rf $tmp_directory`;

				} else {

				print $log "\nSubmitting job to clean up temporary/intermediate files...\n";

				# make sure final output exists before removing intermediate files!
				my $cleanup_cmd = join("\n",
					"if [ -s " . join(" ] && [ -s ", @{$final_outputs{$patient}}) . " ]; then",
					"  $cleanup{$patient}",
					"else",
					'  echo "One or more FINAL OUTPUT FILES is missing; not removing intermediates"',
					"fi"
					);

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_cleanup_' . $patient,
					cmd	=> $cleanup_cmd,
					dependencies	=> join(':', @{$patient_jobs{$patient}}),
					mem		=> '256M',
					hpc_driver	=> $args{hpc_driver}
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

		print $log "\nFINAL OUTPUT:\n" . join("\n  ", @{$final_outputs{$patient}}) . "\n";
		print $log "---\n";
		}

	# collate results
	my $collect_output = join(' ',
		"Rscript $cwd/collect_snv_output.R",
		'-d', $output_directory,
		'-p', $tool_data->{project_name},
		'-g', $tool_data->{gtf}
		);

	if (defined($tool_data->{bamqc}->{callable_bases}->{min_depth}->{tumour})) {
		$collect_output .= " -t $tool_data->{bamqc}->{callable_bases}->{min_depth}->{tumour}";
		}
	if (defined($tool_data->{bamqc}->{callable_bases}->{min_depth}->{normal})) {
		$collect_output .= " -n $tool_data->{bamqc}->{callable_bases}->{min_depth}->{normal}";
		}

	$run_script = write_script(
		log_dir	=> $log_directory,
		name	=> 'combine_variant_calls',
		cmd	=> $collect_output,
		modules	=> [$r_version],
		dependencies	=> join(':', @all_jobs),
		mem		=> '16G',
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
					die("Final STRELKA accounting job: $run_id finished with errors.");
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
my ($tool_config, $data_config, $output_directory);
my $hpc_driver = 'slurm';
my ($remove_junk, $dry_run, $help, $no_wait);
my $panel_of_normals = undef;

# get command line arguments
GetOptions(
	'h|help'	=> \$help,
	'd|data=s'	=> \$data_config,
	't|tool=s'	=> \$tool_config,
	'o|out_dir=s'	=> \$output_directory,
	'c|cluster=s'	=> \$hpc_driver,
	'remove'	=> \$remove_junk,
	'dry-run'	=> \$dry_run,
	'no-wait'	=> \$no_wait,
	'pon=s'		=> \$panel_of_normals
	);

if ($help) {
	my $help_msg = join("\n",
		"Options:",
		"\t--help|-h\tPrint this help message",
		"\t--data|-d\t<string> data config (yaml format)",
		"\t--tool|-t\t<string> tool config (yaml format)",
		"\t--out_dir|-o\t<string> path to output directory",
		"\t--pon\t<string> path to panel of normals (optional: useful for restarting once this has already been generated)",
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
	pon			=> $panel_of_normals,
	hpc_driver		=> $hpc_driver,
	del_intermediates	=> $remove_junk,
	dry_run			=> $dry_run,
	no_wait			=> $no_wait
	);
