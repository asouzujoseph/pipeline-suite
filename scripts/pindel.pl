#!/usr/bin/env perl
### pindel.pl ######################################################################################
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
use List::Util qw(any sum max);
use List::MoreUtils qw(first_index);
use File::Find;
use IO::Handle;

my $cwd = dirname(__FILE__);
require "$cwd/utilities.pl";

our ($reference, $ref_type, $exclude_regions);

####################################################################################################
# version	author		comment
# 1.0		sprokopec	script to run PINDEL

### USAGE ##########################################################################################
# pindel.pl -t tool.yaml -d data.yaml -o /path/to/output/dir -c slurm --remove --dry_run
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
# format command to find mean insert size
sub get_mean_insert_size_command {
	my %args = (
		input	=> undef,
		@_
		);

	my @insert_sizes;

	# extract first 1000000 lines from BAM that pass flag 66
	open (my $bam_fh, "samtools view -f66 $args{input} | head -n 1000000 | cut -f9 |") or die "Could not run samtools view; did you forget to module load samtools?";

	while (<$bam_fh>) {
		my $line = $_;
		chomp($line);
		$line = abs($line);
		next if ($line > 10000);
		push @insert_sizes, $line;
		}

	close($bam_fh);

	return(int(sum(@insert_sizes) / scalar(@insert_sizes)));
	}

# extract mean insert size from sequencing metrics output
sub get_median_insert_size_command {
	my %args = (
		input	=> undef,
		sample	=> undef,
		@_
		);

	my $insert_size;

	open (my $fh, $args{input});

	my $header = <$fh>;
	chomp($header);
	my @info = split /\t/, $header;

	# if this line contains the field headings
	my $insert_size_idx = first_index { $_ eq 'MEDIAN_INSERT_SIZE' } @info;
	my $smp_idx = first_index { $_ eq 'SAMPLE' } @info;
	my $group_idx = first_index { $_ eq 'PAIR_ORIENTATION' } @info;

	while (my $line = <$fh>) {
		chomp($line);
		my @info = split /\t/, $line;

		next if ($info[$smp_idx] ne $args{sample});
		next if ($info[$group_idx] ne 'FR');

		$insert_size = $info[$insert_size_idx];

		}

	return($insert_size);
	}

# format command to run pindel
sub get_pindel_command {
	my %args = (
		input		=> undef,
		output_stem	=> undef,
		intervals	=> undef,
		chrom		=> 'ALL',
		normal_id	=> undef,
		n_cpus		=> 1,
		@_
		);

	my $pindel_command = join(' ',
		'pindel',
		'-f', $reference,
		'-i', $args{input},
		'-o', $args{output_stem} . '_' . $args{chrom},
		'-T', $args{n_cpus},
		'-w 1 -A 20'
		);

	if (defined($args{normal_id})) {
		$pindel_command .= ' --NormalSamples';
		}

	if (defined($args{intervals})) {
		$pindel_command .= ' --include ' . $args{intervals};
		}

	if (defined($args{chrom})) {
		$pindel_command .= ' -c ' . $args{chrom};
		}

	if (('ALL' eq $args{chrom}) || (!defined($args{chrom}))) {
		$pindel_command .= ' --report_interchromosomal_events';
		$pindel_command .= ' --report_long_insertions';
		} else {
		$pindel_command .= ' --report_duplications false';
		}

	if (defined($args{chrom})) {
		$pindel_command .= "\n\n" . join(' ',
			'echo', "'Pindel run complete' >", $args{output_stem} . '_' . $args{chrom} . '.COMPLETE'
			);
		} else {
		$pindel_command .= "\n\n" . join(' ',
			'echo', "'Pindel run complete' >", $args{output_stem} . '.COMPLETE'
			);
		}

	return($pindel_command);
	}

# format command to run pindel (multi-tasking)
sub get_split_pindel_command {
	my %args = (
		input		=> undef,
		output_stem	=> undef,
		chr_file	=> undef,
		intervals	=> undef,
		normal_id	=> undef,
		n_cpus		=> 1,
		@_
		);

	my $pindel_command = 'CHROM=$(sed -n "$SLURM_ARRAY_TASK_ID"p ' . $args{chr_file} . ');';

	$pindel_command .= "\n\n" . join("\n",
		"if [ -s $args{output_stem}" . '_${CHROM}.COMPLETE ]; then',
		"  echo Pindel for \$CHROM already complete",
		'else'
		);

	$pindel_command .= "\n" . join(' ',
		'  pindel',
		'-f', $reference,
		'-i', $args{input},
		'-o', $args{output_stem} . '_$CHROM',
		'-T', $args{n_cpus},
		'-J', $exclude_regions,
		'--report_duplications false',
		'-w 1 -A 20',
		'-c $CHROM'
		);

	if (defined($args{normal_id})) {
		$pindel_command .= ' --NormalSamples';
		}

	if (defined($args{intervals})) {
		$pindel_command .= " --include $args{intervals}";
		}

	$pindel_command .= "\n" . join(' ',
		"  echo 'Pindel run completed successfully' >",
		$args{output_stem} . '_${CHROM}.COMPLETE'
		);

	$pindel_command .= "\nfi";

	return($pindel_command);
	}

# format command to merge SV output
sub get_merge_pindel_command {
	my %args = (
		tmp_dir		=> undef,
		input		=> undef,
		output		=> undef,
		seq_type	=> undef,
		@_
		);

	my $pindel_command = "cd $args{tmp_dir}\n\n";

	# for deletions, inversions, tandem duplications, short insertions
	# 	idx, type, bp1_chr, bp1_start, bp1_end, bp2_chr, bp2_start, bp2_end, support_1, support_2, qual
	$pindel_command .= join(' ',
		"cat $args{input}*_{D,INV,TD}",
		"| grep -v '#'",
		"| awk -v FS=' ' -v OFS='\\t'", 
		"'{ if ((\$1 ~ /^[0-9]+\$/) && (\$27 >= 30))",
		'{ print $1, $2, $8, $10, $13, $8, $11, $14, $16, NA, $27 }}' . "'",
		"> $args{input}\_output_p1.txt"
		);

	# for long insertions:
	# 	idx, type, bp1_chr, bp1_start, bp1_end, bp2_chr, bp2_start, bp2_end, support_1, support_2, qual
	$pindel_command .= "\n\n" . join(' ',
		"cat $args{input}*_LI",
		"| grep -v '#'",
		"| awk -v FS=' ' -v OFS='\\t'",
		"'{ if (\$1 ~ /^[0-9]+\$/)",
		'{ print $1, $2, $4, $5, $5, $4, $8, $8, $7, $10, NA }}' . "'",
		"> $args{input}\_output_p2.txt"
		);

	# for translocations (only target-seq, all other types run per-chromosome):
	# 	idx, type, bp1_chr, bp1_start, bp1_end, bp2_chr, bp2_start, bp2_end, support_1, support_2, qual
	if ($args{seq_type}) {
		$pindel_command .= "\n\n" . join(' ',
			"cat $args{input}*_INT_final",
			"| awk -v FS=' ' -v OFS='\\t'",
			"-v type='INT'",
			"'{ print NR, type, \$2, \$16, \$25, \$6, \$19, \$28, \$12, NA, NA }'",
			"> $args{input}\_output_p3.txt"
			);
		}
	
	$pindel_command .= "\ncat $args{input}\_output_p*.txt > $args{output}";
	$pindel_command .= "\nmd5sum $args{output} > $args{output}.md5";

	return($pindel_command);
	}

# format command to run pindel2vcf
sub get_pindel2vcf_command {
	my %args = (
		tmp_dir		=> undef,
		input		=> undef,
		output		=> undef,
		min_depth	=> undef,
		@_
		);

	my $today = strftime "%Y%m%d", localtime;

	if (!defined($args{min_depth})) { $args{min_depth} = 5; }

	my $pindel_command = "cd $args{tmp_dir}\n";

	$pindel_command .= "for file in $args{input}*COMPLETE; do";

	$pindel_command .= "\n  " . 'STEM=$(echo $file | sed ' . "'s/.COMPLETE//');\n  " . join(' ',
		'pindel2vcf',
		'-r', $reference,
		'-R', $ref_type,
		'-d', $today,
		'-G -pr 3 -ir 3 -il 3 -pl 3 -as 100 -e', $args{min_depth},
		'-P', '$STEM',
		'-v', '$STEM.vcf'
		);

	$pindel_command .= "\n\n  " . 'MD5=$(md5sum $STEM.vcf | cut -f1 -d\' \')';
	$pindel_command .= "\n  " . 'if [ $MD5 == "71ea4d4c63ba1b747f43d8e946d67565" ]; then';
	$pindel_command .= "\n    " . 'echo $STEM.vcf is empty, probably no useful variants found here?';
	$pindel_command .= "\n    " . 'rm $STEM.vcf';
	$pindel_command .= "\n  " . 'fi';

	$pindel_command .= "\n\ndone;";

	$pindel_command .= "\n\n" . join(' ',
		'vcf-concat',
		$args{input} . '*.vcf',
		"| uniq | grep -v -e 'RPL' -e 'SVLEN=0' -e 'SVTYPE=DUP' -e 'SVTYPE=INV' |", 
		# this will remove svtype=RPL, longer insertions (missing sequence details), 
		# 	duplications and inversions
		'vcf-sort -c >',
		$args{output}
		);

	$pindel_command .= "\n\nmd5sum $args{output} > $args{output}.md5";

	return($pindel_command);
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
		print "Initiating Pindel pipeline...\n";
		}

	# load tool config
	my $tool_data_orig = LoadFile($tool_config);
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'pindel');

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_PINDEL_pipeline.log');

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

		$log_file = join('/', $log_directory, 'run_PINDEL_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";
	$log->autoflush;

	print $log "---\n";
	print $log "Running Pindel pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Reference used: $tool_data->{reference}";

	$reference = $tool_data->{reference};
	$ref_type  = $tool_data->{ref_type};

	my $intervals_bed = undef;
	if ( ('wgs' ne $tool_data->{seq_type}) && (defined($tool_data->{intervals_bed})) ) {
		$intervals_bed = $tool_data->{intervals_bed};
		$intervals_bed =~ s/\.bed/_padding100bp.bed/;
		print $log "\n    Target intervals: $intervals_bed"; 
		}

	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---\n";

	my $string;
	if ('targeted' eq $tool_data->{seq_type}) {
		$string = 'ALL';
		} elsif (defined($tool_data->{pindel}->{chromosomes})) {
		$string = $tool_data->{pindel}->{chromosomes};
		} elsif ( ('hg38' eq $tool_data->{ref_type}) || ('hg19' eq $tool_data->{ref_type})) {
		$string = 'chr' . join(',chr', 1..22) . ',chrX,chrY';
		} elsif ( ('GRCh37' eq $tool_data->{ref_type}) || ('GRCh37' eq $tool_data->{ref_type})) {
		$string = join(',', 1..22) . ',X,Y';
		} else {
		$string = 'ALL';
		}

	my @chroms = split(',', $string);

	# find excludable regions
	if ( ('hg38' eq $tool_data->{ref_type}) || ('GRCh38' eq $tool_data->{ref_type}) ) {
		$exclude_regions = '/cluster/projects/pughlab/references/Delly/excludeTemplates/human.hg38.excl.tsv';
		} elsif ( ('hg19' eq $tool_data->{ref_type}) || ('GRCh37' eq $tool_data->{ref_type}) ) {
		$exclude_regions = '/cluster/projects/pughlab/references/Delly/excludeTemplates/human.hg19.excl.tsv';
		}

        # set some binaries
	my $is_multi_slurm = ((scalar(@chroms) > 1) && ('slurm' eq $args{hpc_driver}));
	my $is_targeted = ('targeted' eq $tool_data->{seq_type});
 
	# set tools and versions
	my $pindel	= 'pindel/' . $tool_data->{pindel_version};
	my $samtools	= 'samtools/' . $tool_data->{samtools_version};
	my $vcftools	= 'vcftools/' . $tool_data->{vcftools_version};
	my $r_version	= 'R/'. $tool_data->{r_version};

	my $vcf2maf = undef;
	if (defined($tool_data->{vcf2maf_version})) {
		$vcf2maf = 'vcf2maf/' . $tool_data->{vcf2maf_version};
		$tool_data->{annotate}->{vcf2maf_path} = undef;
		}

	# get user-specified tool parameters
	my $parameters = $tool_data->{pindel}->{parameters};

	# get optional HPC group
	my $hpc_group = defined($tool_data->{hpc_group}) ? "-A $tool_data->{hpc_group}" : undef;

	### RUN ###########################################################################################
	my ($run_script, $run_id, $link, $cleanup_cmd, $should_run_final);
	my @all_jobs;

	# if multiple chromosomes are to be run (separately):
	my $chr_file = join('/', $output_directory, 'chromosome_list.txt');
	if (scalar(@chroms) > 1) {
		open (my $chr_list, '>', $chr_file) or die "Could not open $chr_file for writing.";	
		foreach my $chrom ( @chroms ) {
			print $chr_list "$chrom\n";
			}
		}

	# get sample data
	my $smp_data = LoadFile($data_config);

	unless($args{dry_run}) {
		print "Processing " . scalar(keys %{$smp_data}) . " patients.\n";
		}

	# insert sizes are collected as part of pipeline-suite QC step, so let's use that
	my $bam_metrics_file;
	my $qc_directory = $output_directory . '/../BAMQC/SequenceMetrics';
	if (-e $qc_directory) {
		my @qc_files = _get_files($qc_directory, 'InsertSizes.tsv');
		if (scalar(@qc_files) > 0) {
			@qc_files = sort(@qc_files);
			$bam_metrics_file = $qc_files[-1];
			print $log "\n>> Extracting insert sizes from: $bam_metrics_file\n";
			}
		}

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient";

		# find bams
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};

		if (scalar(@tumour_ids) == 0) {
			print $log "\n>> No tumour BAM provided. Skipping $patient...\n";
			next;
			}

		# create some directories
		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

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

		# get normal stats (if present)
		my $normal_insert_size = 152; # expected read length + 1
		my $normal = undef;
		if (scalar(@normal_ids) > 0) {
			$normal = $normal_ids[0];
			if (defined($bam_metrics_file)) {
				$normal_insert_size = max(
					$normal_insert_size,
					get_median_insert_size_command(
						input 	=> $bam_metrics_file,
						sample	=> $normal
						)
					);
				} else {
				$normal_insert_size = max(
					$normal_insert_size,
					get_mean_insert_size_command(
						input => $smp_data->{$patient}->{normal}->{$normal}
						)
					);
				}
			}

		# create an array to hold final outputs and all patient job ids
		my (@final_outputs, @patient_jobs);

		foreach my $sample (@tumour_ids) {

			my @sample_jobs;

			# if there are any samples to run, we will run the final combine job
			$should_run_final = 1;

			print $log "\n  SAMPLE: $sample\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			my $tmp_directory = join('/', $patient_directory, 'TEMP');
			unless(-e $tmp_directory) { make_path($tmp_directory); }

			# indicate this should be removed at the end
			$cleanup_cmd .= "\n" . "rm -rf $tmp_directory";

			# generate necessary samples.tsv
			my $sample_sheet = join('/', $sample_directory, 'pindel_config.txt');

			if ('Y' eq missing_file($sample_sheet)) {
				open(my $fh, '>', $sample_sheet) or die "Cannot open '$sample_sheet' !";

				my $tumor_insert_size = 152; # expected read length + 1
				if (defined($bam_metrics_file)) {
					$tumor_insert_size = max(
						$tumor_insert_size,
						get_median_insert_size_command(
							input 	=> $bam_metrics_file,
							sample	=> $sample
							)
						);
					} else {
					$tumor_insert_size = max(
						$tumor_insert_size,
						get_mean_insert_size_command(
							input => $smp_data->{$patient}->{tumour}->{$sample} 
							)
						);
					}

				print $fh "$smp_data->{$patient}->{tumour}->{$sample}\t$tumor_insert_size\t$sample\n";

				# add the normal (if present)
				if (scalar(@normal_ids) > 0) {
					my $normal_bam = $smp_data->{$patient}->{normal}->{$normal};
					print $fh "$normal_bam\t$normal_insert_size\t$normal\n";
					}

				close $fh;
				}

			# indicate output stem
			my $output_stem = join('/', $tmp_directory, $sample . '_pindel');
			my $merged_file = join('/', $sample_directory, $sample . '_combined_Pindel_output.txt');
			my $merged_vcf = join('/', $sample_directory, $sample . '_Pindel_filtered.vcf');

			# create Pindel command
			my @pindel_jobs;
			my $pindel_command;

			$run_id = '';

			if (!$is_targeted && $is_multi_slurm) {

				$pindel_command = get_split_pindel_command(
					input		=> $sample_sheet, 
					output_stem	=> $output_stem,
					normal_id	=> $normal,
					chr_file	=> $chr_file,
					intervals	=> $intervals_bed,
					chrom		=> '$CHROM',
					n_cpus		=> $parameters->{pindel}->{n_cpu}
					);

				# check if this should be run
				if ('Y' eq missing_file($merged_vcf . '.md5')) {

					# record command (in log directory) and then run job
					print $log "  >> Submitting job for Pindel...\n";

					$run_script = write_script(
						log_dir	=> $log_directory,
						name	=> 'run_pindel_' . $sample,
						cmd	=> $pindel_command,
						modules	=> [$pindel],
						max_time	=> $parameters->{pindel}->{time},
						mem		=> $parameters->{pindel}->{mem},
						cpus_per_task	=> $parameters->{pindel}->{n_cpu},
						hpc_driver	=> $args{hpc_driver},
						extra_args	=> [$hpc_group, '--array=1-'. scalar(@chroms)]
						);

					$run_id = submit_job(
						jobname		=> 'run_pindel_' . $sample,
						shell_command	=> $run_script,
						hpc_driver	=> $args{hpc_driver},
						dry_run		=> $args{dry_run},
						log_file	=> $log
						);

					push @pindel_jobs, $run_id;
					push @sample_jobs, $run_id;
					push @all_jobs, $run_id;
					} else {
					print $log "  >> Skipping Pindel because this has already been completed!\n";
					}

				} else {

				foreach my $chr ( @chroms ) {

					$pindel_command = get_pindel_command(
						input		=> $sample_sheet, 
						output_stem	=> $output_stem,
						intervals	=> $intervals_bed,
						normal_id	=> $normal,
						chrom		=> $chr,
						n_cpus		=> $parameters->{pindel}->{n_cpu}
						);

					# check if this should be run
					if ( ('Y' eq missing_file($merged_vcf . '.md5')) &&
						('Y' eq missing_file($output_stem . '_' . $chr . '.COMPLETE'))) {

						# record command (in log directory) and then run job
						print $log "  >> Submitting job for Pindel ($chr)...\n";

						$run_script = write_script(
							log_dir	=> $log_directory,
							name	=> 'run_pindel_' . $sample . '_' . $chr,
							cmd	=> $pindel_command,
							modules	=> [$pindel],
							max_time	=> $parameters->{pindel}->{time},
							mem		=> $parameters->{pindel}->{mem},
							cpus_per_task	=> $parameters->{pindel}->{n_cpu},
							hpc_driver	=> $args{hpc_driver},
							extra_args	=> [$hpc_group]
							);

						$run_id = submit_job(
							jobname		=> 'run_pindel_' . $sample . '_' . $chr,
							shell_command	=> $run_script,
							hpc_driver	=> $args{hpc_driver},
							dry_run		=> $args{dry_run},
							log_file	=> $log
							);

						push @pindel_jobs, $run_id;
						push @sample_jobs, $run_id;
						push @all_jobs, $run_id;
						} else {
						print $log "  >> Skipping Pindel ($chr) because this has already been completed!\n";
						}
					}
				}

			unless('wgs' eq $tool_data->{seq_type}) {

				# merge chromosome output (for mavis)
				my $merge_command = get_merge_pindel_command(
					input		=> $sample . '_pindel',
					output		=> $merged_file,
					tmp_dir		=> $tmp_directory,
					seq_type	=> $is_targeted
					);

				# check if this should be run
				if ('Y' eq missing_file($merged_file . '.md5')) {

					# record command (in log directory) and then run job
					print $log "  >> Submitting job for merge step...\n";

					$run_script = write_script(
						log_dir	=> $log_directory,
						name	=> 'run_merge_pindel_' . $sample,
						cmd	=> $merge_command,
						dependencies	=> join(':', @pindel_jobs),
						max_time	=> $parameters->{convert}->{time},
						mem		=> $parameters->{convert}->{mem},
						hpc_driver	=> $args{hpc_driver},
						extra_args	=> [$hpc_group]
						);

					$run_id = submit_job(
						jobname		=> 'run_merge_pindel_' . $sample,
						shell_command	=> $run_script,
						hpc_driver	=> $args{hpc_driver},
						dry_run		=> $args{dry_run},
						log_file	=> $log
						);

					push @sample_jobs, $run_id;
					push @all_jobs, $run_id;
					} else {
					print $log "  >> Skipping merge step because this has already been completed!\n";
					}
				}

			# merge and convert to VCF
			my $convert_command = get_pindel2vcf_command(
				input		=> $sample . '_pindel',
				output		=> $merged_vcf,
				min_depth	=> $parameters->{convert}->{filter_depth},
				tmp_dir		=> $tmp_directory
				);

			# check if this should be run
			if ('Y' eq missing_file($merged_vcf . '.md5')) {

				# record command (in log directory) and then run job
				print $log "  >> Submitting job for Pindel2VCF...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_pindel2vcf_' . $sample,
					cmd	=> $convert_command,
					modules	=> [$pindel, $vcftools],
					dependencies	=> join(':', @pindel_jobs),
					max_time	=> $parameters->{convert}->{time},
					mem		=> $parameters->{convert}->{mem},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_pindel2vcf_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @sample_jobs, $run_id;
				push @all_jobs, $run_id;
				} else {
				print $log "  >> Skipping Pindel2VCF because this has already been completed!\n";
				}

			### Run variant annotation (VEP + vcf2maf)
			my $final_vcf = join('/', $sample_directory, $sample . '_Pindel_filtered_annotated.vcf');
			my $final_maf = join('/', $sample_directory, $sample . '_Pindel_filtered_annotated.maf');

			my $vcf2maf_cmd = get_vcf2maf_command(
				input		=> $merged_vcf,
				tumour_id	=> $sample,
				normal_id	=> $normal,
				reference	=> $reference,
				ref_type	=> $tool_data->{ref_type},
				output		=> $final_maf,
				tmp_dir		=> $tmp_directory,
				parameters	=> $tool_data->{annotate}
				);

			# check if this should be run
			if ('Y' eq missing_file($final_maf . '.md5')) {

				if ('N' eq missing_file("$tmp_directory/$sample\_Pindel_filtered.vep.vcf")) {
					`rm $tmp_directory/$sample\_Pindel_filtered.*`;
					}

				# IF THIS FINAL STEP IS SUCCESSFULLY RUN,
				$vcf2maf_cmd .= "\n\n" . join("\n",
					"if [ -s " . join(" ] && [ -s ", $final_maf) . " ]; then",
					"  md5sum $final_maf > $final_maf.md5",
					"  mv $tmp_directory/$sample" . "_Pindel_filtered.vep.vcf $final_vcf",
					"  md5sum $final_vcf > $final_vcf.md5",
					"  bgzip $final_vcf",
					"  tabix -p vcf $final_vcf.gz",
					"else",
					'  echo "FINAL OUTPUT MAF is missing; not running md5sum/bgzip/tabix..."',
					"fi"
					);

				# record command (in log directory) and then run job
				print $log "  >> Submitting job for vcf2maf...\n";

				$run_script = write_script(
					log_dir => $log_directory,
					name    => 'run_vcf2maf_and_VEP_' . $sample,
					cmd     => $vcf2maf_cmd,
					modules => ['perl', $samtools, 'tabix', $vcf2maf],
					dependencies    => $run_id,
					cpus_per_task	=> $tool_data->{annotate}->{n_cpus},
					max_time        => $tool_data->{annotate}->{time},
					mem             => $tool_data->{annotate}->{mem},
					hpc_driver      => $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname         => 'run_vcf2maf_and_VEP_' . $sample,
					shell_command   => $run_script,
					hpc_driver      => $args{hpc_driver},
					dry_run         => $args{dry_run},
					log_file	=> $log
					);

				push @sample_jobs, $run_id;
				push @all_jobs, $run_id;
				} else {
				print $log "  >> Skipping vcf2maf because this has already been completed!\n";
				}

			push @final_outputs, $final_maf;
			push @patient_jobs, @sample_jobs;

			if (scalar(@sample_jobs) == 0) { `rm -rf $tmp_directory`; }

			}

		# should intermediate files be removed
		# run per patient
		if ($args{del_intermediates}) {

			unless (scalar(@patient_jobs) == 0) {

				print $log ">> Submitting job to clean up temporary/intermediate files...\n";

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
			"Rscript $cwd/collect_snv_output.R",
			'-d', $output_directory,
			'-p', $tool_data->{project_name},
			);

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'combine_pindel_output',
			cmd	=> $collect_output,
			modules	=> [$r_version],
			dependencies	=> join(':', @all_jobs),
			mem		=> '4G',
			max_time	=> '12:00:00',
			hpc_driver	=> $args{hpc_driver},
			extra_args	=> [$hpc_group]
			);

		$run_id = submit_job(
			jobname		=> 'combine_pindel_output',
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
