#!/usr/bin/env perl
### somaticsniper.pl ###############################################################################
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
our ($reference, $intervals_bed, $pon) = undef;

####################################################################################################
# version       author		comment
# 1.0		sprokopec       script to run SomaticSniper with options for T/N, PoN and T only

### USAGE ##########################################################################################
# somaticsniper.pl -t tool.yaml -d data.yaml -o /path/to/output/dir -c slurm --remove --dry_run
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
# format command to run SomaticSniper on T/N pairs
sub get_somaticsniper_command {
	my %args = (
		tumour		=> undef,
		normal		=> undef,
		output_stem	=> undef,
		@_
		);

	my $somaticsniper_command = join(' ',
		'bam-somaticsniper',
		'-f', $reference,
		'-F vcf',
		'-q 1 -Q 40 -G -L',
		$args{tumour},
		$args{normal},
		$args{output_stem} . '.vcf',
		);

	return($somaticsniper_command);
	}

# prepare indel pileup
sub get_pileup_command {
	my %args = (
		bam		=> undef,
		output		=> undef,
		@_
		);

	my $pileup_command = join(' ',
		'bcftools mpileup -A -B',
		'-f', $reference,
		$args{bam},
		'|', 'bcftools call -c',
		'|', 'vcfutils.pl varFilter -Q 20',
		'|', "awk 'NR > 55 { print }'", 
		'>', $args{output}
		);

	return($pileup_command);
	}

# format command to run somaticsnipers snpfilter command
sub get_snp_filter_command {
	my %args = (
		input	=> undef,
		indels	=> undef,
		output	=> undef,
		@_
		);

	my $filter_command = 'DIRNAME=$(which bam-somaticsniper | xargs dirname)';

	$filter_command .= "\n\n" . join(' ',
		'perl $DIRNAME/snpfilter.pl',
		'--snp-file', $args{input},
		'--indel-file', $args{indels},
		'--out-file', $args{output}
		);

	return($filter_command);
	}

# format command to run bam-readcount
sub get_readcounts_command {
	my %args = (
		snp_filter	=> undef,
		positions	=> undef,
		tumour_bam	=> undef,
		output		=> undef,
		@_
		);

	my $rc_command = 'DIRNAME=$(which bam-somaticsniper | xargs dirname)';

	$rc_command .= "\n\n" . join(' ',
		'perl $DIRNAME/prepare_for_readcount.pl',
		'--snp-file', $args{snp_filter},
		'--out-file', $args{positions}
		);

	$rc_command .= "\n\n" . join(' ',
		'bam-readcount',
		'-b 15 -q 1 -w 0',
		'-f', $reference,
		'-l', $args{positions},
		$args{tumour_bam},
		'>', $args{output}
		);

	return($rc_command);
	}

# format command to run somaticsnipers fpfilter command
sub get_fp_filter_command {
	my %args = (
		snp_filter	=> undef,
		readcounts	=> undef,
		hc_output	=> undef,
		@_
		);
	
	my $filter_command = 'DIRNAME=$(which bam-somaticsniper | xargs dirname)';

	$filter_command .= "\n\n" . join(' ',
		'perl $DIRNAME/fpfilter.pl',
		'--snp-file', $args{snp_filter},
		'--readcount-file', $args{readcounts}
		);

	$filter_command .= "\n\n" . join(' ',
		'perl $DIRNAME/highconfidence.pl',
		'--snp-file', $args{snp_filter} . '.fp_pass',
		'--min-mapping-quality 40 --min-somatic-score 40',
		'--out-file', $args{hc_output}
		);

	return($filter_command);
	}

# format command to run additional filtering (pon and/or target regions)
sub get_extra_filter_command {
	my %args = (
		input		=> undef,
		intervals	=> undef,
		pon		=> undef,
		output		=> undef,
		@_
		);

	my $filter_command;

	if ( (defined($args{intervals})) && (!defined($args{pon})) ) {

		$filter_command .= join("\n",
			join(' ', 'bgzip -f -c', $args{input}, '>', $args{input} . '.gz'),
			join(' ', 'tabix -f -p vcf', $args{input} . '.gz')
			);

		$filter_command .= "\n\n" . join(' ',
			'bcftools filter',
			'-R', $args{intervals},
			$args{input} . '.gz',
			'| vcf-sort -c',
			'| uniq',
			'>', $args{output}
			);

		$filter_command .= "\n\nrm $args{input}.gz*";

		} elsif ( (!defined($args{intervals})) && (defined($args{pon})) ) {

		$filter_command .= join(' ',
			'vcftools',
			'--vcf', $args{input},
			'--exclude-positions', $args{pon},
			'--stdout --recode',
			'>', $args{output}
			);

		} elsif ( (defined($args{intervals})) && (defined($args{pon})) ) {
	
		$filter_command .= join("\n",
			join(' ', 'bgzip -f -c', $args{input}, '>', $args{input} . '.gz'),
			join(' ', 'tabix -f -p vcf', $args{input} . '.gz')
			);

		$filter_command .= "\n\n" . join(' ',
			'bcftools filter',
			'-R', $args{intervals},
			$args{input} . '.gz',
			'| vcftools --vcf -',
			'--exclude-positions', $args{pon},
			'--stdout --recode',
			'| vcf-sort -c | uniq',
			'>', $args{output}
			);

		$filter_command .= "\n\nrm $args{input}.gz*";

		}

	return($filter_command);
	}

### MAIN ###########################################################################################
sub main {
	my %args = (
		tool_config		=> undef,
		data_config		=> undef,
		output_directory	=> undef,
		pon			=> undef,
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
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'somaticsniper');

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_SomaticSniper_pipeline.log');

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

		$log_file = join('/', $log_directory, 'run_SomaticSniper_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";
	$log->autoflush;

	print $log "---\n";
	print $log "Running SomaticSniper variant calling pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Reference used: $tool_data->{reference}";

	$reference = $tool_data->{reference};

	if (defined($tool_data->{somaticsniper}->{pon})) {
		print $log "\n      Panel of Normals: $tool_data->{somaticsniper}->{pon}";
		$pon = $tool_data->{somaticsniper}->{pon};
		} elsif (defined($args{pon})) {
		print $log "\n      Panel of Normals: $args{pon}";
		$pon = $args{pon};
		} else {
		print $log "\n      No panel of normals defined! Additional filtering step will not be performed.";
		}

	if (defined($tool_data->{intervals_bed})) {
		$intervals_bed = $tool_data->{intervals_bed};
		$intervals_bed =~ s/\.bed/_padding100bp.bed/;
		print $log "\n    Target intervals (exome): $intervals_bed";
		}

	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---";

	# set tools and versions
	my $somaticsniper	= $tool_data->{somaticsniper_version};
	my $samtools	= 'samtools/' . $tool_data->{samtools_version};
	my $vcftools	= 'vcftools/' . $tool_data->{vcftools_version};
	my $r_version	= 'R/'. $tool_data->{r_version};

	# get user-specified tool parameters
	my $parameters = $tool_data->{somaticsniper}->{parameters};

	### RUN ###########################################################################################
	# get sample data
	my $smp_data = LoadFile($data_config);

	my ($run_script, $run_id, $link, $cleanup_cmd, $sniper_id, $norm_pile_id, $tum_pile_id);
	my @all_jobs;

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient\n";

		# find bams
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};

		if (scalar(@normal_ids) == 0) {
			print $log "\n>>No normal BAM provided. Skipping somatic variant calling in $patient...\n";
			next;
			}

		# create some directories
		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my $tmp_directory = join('/', $patient_directory, 'TEMP');
		unless(-e $tmp_directory) { make_path($tmp_directory); }

		# indicate this should be removed at the end
		$cleanup_cmd = "rm -rf $tmp_directory";

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

		# create an array to hold final outputs and all patient job ids
		my (@final_outputs, @patient_jobs);

		# get normal pileup
		my $norm_pileup = join('/', $patient_directory, $normal_ids[0] . '_indel.pileup');
		my $norm_pileup_cmd = get_pileup_command(
			bam		=> $smp_data->{$patient}->{normal}->{$normal_ids[0]},
			output		=> $norm_pileup
			);

		$norm_pileup_cmd .= "\n\nmd5sum $norm_pileup > $norm_pileup.md5";

		$cleanup_cmd .= "\nrm $norm_pileup";

		$norm_pile_id = '';

		# check if this should be run
		if ('Y' eq missing_file("$norm_pileup.md5")) {

			# record command (in log directory) and then run job
			print $log "Submitting job for INDEL pileup (normal)...\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_get_normal_pileup_' . $normal_ids[0],
				cmd	=> $norm_pileup_cmd,
				modules	=> [$samtools],
				max_time	=> $parameters->{pileup}->{time},
				mem		=> $parameters->{pileup}->{mem},
				hpc_driver	=> $args{hpc_driver}
				);

			$norm_pile_id = submit_job(
				jobname		=> 'run_get_normal_pileup_' . $normal_ids[0],
				shell_command	=> $run_script,
				hpc_driver	=> $args{hpc_driver},
				dry_run		=> $args{dry_run},
				log_file	=> $log
				);

			push @patient_jobs, $norm_pile_id;
			push @all_jobs, $norm_pile_id;
			}
		else {
			print $log "Skipping pileup (normal) because this has already been completed!\n";
			}

		# for each tumour sample
		foreach my $sample (@tumour_ids) {

			print $log "  SAMPLE: $sample\n\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			$sniper_id = '';
			$tum_pile_id = '';
			$run_id = '';

			# run SomaticSniper
			my $output_stem = join('/', $sample_directory, $sample . '_SomaticSniper');
			$cleanup_cmd .= "\nrm $output_stem.vcf";

			my $somaticsniper_command = get_somaticsniper_command(
				tumour		=> $smp_data->{$patient}->{tumour}->{$sample},
				normal		=> $smp_data->{$patient}->{normal}->{$normal_ids[0]},
				output_stem	=> $output_stem
				);

			$somaticsniper_command .= "\n\nmd5sum $output_stem.vcf > $output_stem.vcf.md5";

			# check if this should be run
			if ('Y' eq missing_file($output_stem . '.vcf.md5')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for SomaticSniper...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_somaticsniper_' . $sample,
					cmd	=> $somaticsniper_command,
					modules	=> [$somaticsniper],
					max_time	=> $parameters->{somaticsniper}->{time},
					mem		=> $parameters->{somaticsniper}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$sniper_id = submit_job(
					jobname		=> 'run_somaticsniper_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $sniper_id;
				push @all_jobs, $sniper_id;
				}
			else {
				print $log "Skipping SomaticSniper because this has already been completed!\n";
				}

			# collect indel pileup (necessary for filtering)
			my $tumour_pileup = join('/', $sample_directory, $sample . '_indel.pileup');
			my $tumour_pileup_cmd = get_pileup_command(
				bam		=> $smp_data->{$patient}->{tumour}->{$sample},
				output		=> $tumour_pileup
				);

			$tumour_pileup_cmd .= "\n\nmd5sum $tumour_pileup > $tumour_pileup.md5";

			$cleanup_cmd .= "\nrm $tumour_pileup";

			# check if this should be run
			if ('Y' eq missing_file("$tumour_pileup.md5")) {

				# record command (in log directory) and then run job
				print $log "Submitting job for INDEL pileup (tumour)...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_get_tumour_pileup_' . $sample,
					cmd	=> $tumour_pileup_cmd,
					modules	=> [$samtools],
					max_time	=> $parameters->{pileup}->{time},
					mem		=> $parameters->{pileup}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$tum_pile_id = submit_job(
					jobname		=> 'run_get_tumour_pileup_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $tum_pile_id;
				push @all_jobs, $tum_pile_id;
				}
			else {
				print $log "Skipping pileup (tumour) because this has already been completed!\n";
				}

			# apply somaticsniper snpfilter to initial results
			my $snp_filter = $output_stem . '_tumour_normal.SNPfilter';
			my $filter_command = get_snp_filter_command(
				input	=> $output_stem . '.vcf',
				indels	=> $norm_pileup,
				output	=> join('/', $sample_directory, 'normal_filtered.SNPfilter')
				);

			$filter_command .= "\n\n" . get_snp_filter_command(
				input	=> join('/', $sample_directory, 'normal_filtered.SNPfilter'),
				indels	=> $tumour_pileup,
				output	=> $snp_filter 
				);

			$cleanup_cmd .= "\nrm " . join('/', $sample_directory, '*SNPfilter');

			# check if this should be run
			if ('Y' eq missing_file($snp_filter)) {

				# record command (in log directory) and then run job
				print $log "Submitting job for snpFilter...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_snpfilter_' . $sample,
					cmd	=> $filter_command,
					modules	=> ['perl', $somaticsniper],
					dependencies	=> join(':', $sniper_id, $norm_pile_id, $tum_pile_id),
					max_time	=> '04:00:00', 
					mem		=> '1G',
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_snpfilter_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				}
			else {
				print $log "Skipping snpfilter because this has already been completed!\n";
				}

			# get readcounts
			my $position_file = $snp_filter . '.pos';
			my $bam_readcounts = $position_file . '.readcounts';
			my $readcount_command = get_readcounts_command(
				snp_filter	=> $snp_filter,
				positions	=> $position_file,
				tumour_bam	=> $smp_data->{$patient}->{tumour}->{$sample},
				output		=> $bam_readcounts
				);

			$readcount_command .= "\n\nmd5sum $bam_readcounts > $bam_readcounts.md5";

			$cleanup_cmd .= "\nrm $position_file";
			$cleanup_cmd .= "\nrm $bam_readcounts";

			# check if this should be run
			if ('Y' eq missing_file("$bam_readcounts.md5")) {

				# record command (in log directory) and then run job
				print $log "Submitting job for bam-readcount...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_get_readcounts_' . $sample,
					cmd	=> $readcount_command,
					modules	=> ['perl', 'bam-readcount', $somaticsniper],
					dependencies	=> $run_id,
					max_time	=> $parameters->{readcount}->{time},
					mem		=> $parameters->{readcount}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_get_readcounts_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				}
			else {
				print $log "Skipping bam-readcount because this has already been completed!\n";
				}

			# apply somaticsnipers false positive filter
			my $hc_vcf = $output_stem . '_hc.vcf';
			my $filtered_vcf = $output_stem . '_hc_filtered.vcf';

			my $fp_filter_command;

			# apply extra filters (ie, target regions or PoN if provided)
			if ( (defined($intervals_bed)) || (defined($pon)) ) {

				$fp_filter_command = get_fp_filter_command(
					snp_filter	=> $snp_filter,
					readcounts	=> $bam_readcounts,
					hc_output	=> $hc_vcf
					);

				$fp_filter_command .= "\n\nmd5sum $hc_vcf > $hc_vcf.md5";

				$fp_filter_command .= "\n\n" . get_extra_filter_command(
					input		=> $hc_vcf,
					intervals	=> $intervals_bed,
					pon		=> $pon,
					output		=> $filtered_vcf,
					tmp_dir		=> $tmp_directory
					);

				$fp_filter_command .= "\n\nmd5sum $filtered_vcf > $filtered_vcf.md5";
				$cleanup_cmd .= "\nrm $hc_vcf";

				} else {

				$fp_filter_command = get_fp_filter_command(
					snp_filter	=> $snp_filter,
					readcounts	=> $bam_readcounts,
					hc_output	=> $filtered_vcf
					);

				$fp_filter_command .= "\n\nmd5sum $filtered_vcf > $filtered_vcf.md5";
				}

			$cleanup_cmd .= "\nrm $filtered_vcf";

			# check if this should be run
			if ('Y' eq missing_file("$filtered_vcf.md5")) {

				# record command (in log directory) and then run job
				print $log "Submitting job for final filters...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_final_filters_' . $sample,
					cmd	=> $fp_filter_command,
					modules	=> ['perl', $somaticsniper, $samtools, 'tabix', $vcftools],
					dependencies	=> $run_id,
					max_time	=> $parameters->{filter}->{time},
					mem		=> $parameters->{filter}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_final_filter_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				}
			else {
				print $log "Skipping final filter because this has already been completed!\n";
				}

			### Run variant annotation (VEP + vcf2maf)
			my $final_vcf = $output_stem . "_filtered_annotated.vcf";
			my $final_maf = $output_stem . "_filtered_annotated.maf";

			my $vcf2maf_cmd = get_vcf2maf_command(
				input		=> $filtered_vcf,
				tumour_id	=> $sample,
				normal_id	=> $normal_ids[0],
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

				if ('N' eq missing_file("$tmp_directory/$sample\_SomaticSniper_hc_filtered.vep.vcf")) {
					`rm $tmp_directory/$sample\_SomaticSniper_hc_filtered.vep.vcf`;
					}

				# IF THIS FINAL STEP IS SUCCESSFULLY RUN,
				$vcf2maf_cmd .= "\n\n" . join("\n",
					"if [ -s " . join(" ] && [ -s ", $final_maf) . " ]; then",
					"  md5sum $final_maf > $final_maf.md5",
					"  mv $tmp_directory/$sample" . "_SomaticSniper_hc_filtered.vep.vcf $final_vcf",
					"  md5sum $final_vcf > $final_vcf.md5",
					"  bgzip $final_vcf",
					"  tabix -p vcf $final_vcf.gz",
					"else",
					'  echo "FINAL OUTPUT MAF is missing; not running md5sum/bgzip/tabix..."',
					"fi"
					);

				# record command (in log directory) and then run job
				print $log "Submitting job for vcf2maf...\n";

				$run_script = write_script(
					log_dir => $log_directory,
					name    => 'run_vcf2maf_and_VEP_' . $sample,
					cmd     => $vcf2maf_cmd,
					modules => ['perl', $samtools, 'tabix'],
					dependencies    => $run_id,
					cpus_per_task	=> 4,
					max_time        => $tool_data->{annotate}->{time},
					mem             => $tool_data->{annotate}->{mem},
					hpc_driver      => $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname         => 'run_vcf2maf_and_VEP_' . $sample,
					shell_command   => $run_script,
					hpc_driver      => $args{hpc_driver},
					dry_run         => $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				}
			else {
				print $log "Skipping vcf2maf because this has already been completed!\n";
				}

			push @final_outputs, $final_maf;
			}

		# should intermediate files be removed
		# run per patient
		if ($args{del_intermediates}) {

			if (scalar(@patient_jobs) == 0) {
				`rm -rf $tmp_directory`;

				} else {

				print $log "Submitting job to clean up temporary/intermediate files...\n";

				# make sure final output exists before removing intermediate files!
				my @files_to_check;
				foreach my $tmp ( @final_outputs ) {
					push @files_to_check, $tmp . '.md5';
					}

				$cleanup_cmd = join("\n",
					"if [ -s " . join(" ] && [ -s ", @files_to_check) . " ]; then",
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

		print $log "\nFINAL OUTPUT:\n" . join("\n  ", @final_outputs) . "\n";
		print $log "---\n";
		}

	# collate results
	my $collect_output = join(' ',
		"Rscript $cwd/collect_snv_output.R",
		'-d', $output_directory,
		'-p', $tool_data->{project_name}
		);

	$run_script = write_script(
		log_dir	=> $log_directory,
		name	=> 'combine_variant_calls',
		cmd	=> $collect_output,
		modules	=> [$r_version],
		dependencies	=> join(':', @all_jobs),
		mem		=> '4G',
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
			hpc_driver	=> $args{hpc_driver},
			kill_on_error	=> 0
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
					die("Final MuTect accounting job: $run_id finished with errors.");
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
	'h|help'			=> \$help,
	'd|data=s'			=> \$data_config,
	't|tool=s'			=> \$tool_config,
	'o|out_dir=s'			=> \$output_directory,
	'c|cluster=s'			=> \$hpc_driver,
	'remove'			=> \$remove_junk,
	'dry-run'			=> \$dry_run,
	'no-wait'			=> \$no_wait,
	'pon=s'				=> \$panel_of_normals
	);

if ($help) {
	my $help_msg = join("\n",
		"Options:",
		"\t--help|-h\tPrint this help message",
		"\t--data|-d\t<string> data config (yaml format)",
		"\t--tool|-t\t<string> tool config (yaml format)",
		"\t--out_dir|-o\t<string> path to output directory",
		"\t--pon\t<string> path to panel of normals (optional)",
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
	no_wait			=> $no_wait,
	pon			=> $panel_of_normals
	);
