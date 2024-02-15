#!/usr/bin/env perl
### novobreak.pl ###################################################################################
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
use List::Util 'first';
use IO::Handle;

my $cwd = dirname(__FILE__);
require "$cwd/utilities.pl";

# define some global variables
our ($reference, $bwa_ref, $pon, $intervals_bed) = undef;

####################################################################################################
# version       author		comment
# 1.0		sprokopec       script to run NovoBreak

### USAGE ##########################################################################################
# novobreak.pl -t tool_config.yaml -d data_config.yaml -o /path/to/output/dir -c slurm --remove --dry_run
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
# format command to run NovoBreak
sub get_novobreak_command {
	my %args = (
		tumour_id	=> undef,
		tumour_bam	=> undef,
		normal_bam	=> undef,
		out_dir		=> undef,
		@_
		);

	my $nb_command = "cd $args{out_dir}\n";

	$nb_command .= join("\n",
		"if [ -s $args{tumour_id}" . '_nb_kmer.out.md5 ]; then',
		"  echo Intermediate output file: $args{tumour_id}" . '_nb_kmer.out.md5 already exists.',
		"else",
		"  echo 'Running novoBreak...'"
		);

	$nb_command .= "\n  " . join(' ',
		'novoBreak',
		'-i', $args{tumour_bam},
		'-c', $args{normal_bam},
		'-r', $reference,
		'-o', $args{tumour_id} . '_nb_kmer.out'
		);

	$nb_command .= "\n  md5sum $args{tumour_id}\_nb\_kmer.out > $args{tumour_id}\_nb\_kmer.out.md5";

	$nb_command .="\nfi";

	return($nb_command);
	}

# format command to group SVs by reads 
sub get_group_by_reads_command {
	my %args = (
		directory	=> undef,
		nb_file		=> undef,
		@_
		);

	my $group_command = join("\n",
		"cd $args{directory}\n",
		"echo 'Processing kmers...'",
		'if [ ! -s somaticreads.srtnm.bam.md5 ]; then',
		"  echo '>> sorting somaticreads.bam by query name...'",
		'  samtools sort -T . -n -o somaticreads.srtnm.bam somaticreads.bam;',
		'  md5sum somaticreads.srtnm.bam > somaticreads.srtnm.bam.md5;',
		'  rm {somaticreads,germlinereads}.bam;',
		'fi',
		'if [ ! -s bam2fq.status ]; then',
		"  echo '>> extracting reads from somaticreads.srtnm.bam...'",
		'  samtools bam2fq -1 read1.fq -2 read2.fq somaticreads.srtnm.bam;',
		"  echo 'samtools bam2fq COMPLETE' > bam2fq.status",
		'fi',
		'if [ ! -s bp_reads.tsv.md5 ]; then',
		"  echo '>> extracting and sorting kmers...'",
		'  group_bp_reads.pl ' . $args{nb_file} . ' read1.fq read2.fq > bp_reads.tsv;',
		'  md5sum bp_reads.tsv > bp_reads.tsv.md5',
		'  if [ -s bp_reads.tsv.md5 ]; then',
		"    rm somaticreads.srtnm.bam;",
		'    rm read{1,2}.fq;',
		"    rm $args{nb_file};",
		'  fi',
		'fi'
		);

	return($group_command);
	}

# format command to prepare ssake 
sub get_prep_ssake_command {
	my %args = (
		output_file	=> undef,
		n_cpus		=> 1,
		@_
		);

	my $nb_output = $args{output_file};
	my $cpu_count = $args{n_cpus} - 1;
	my $part1_command = join("\n",
		'  if [ -s bp_reads.tsv.md5 ] && [ ! -s ssake.sam.md5 ]; then',
		"    echo 'Processing breakpoints...'",
		'    if [ ! -s ssake.fa.md5 ]; then',
		"      echo '>> converting kmers to fasta...'",
		'      cls=$(tail -1 bp_reads.tsv | cut -f1);',
		'      rec=$(echo $cls/' . $args{n_cpus} . ' | bc);',
		'      rec=$((rec+1));',
		'      awk -v rec=$rec ' . "'{print" . ' > int($1/rec)".txt"' . "}' bp_reads.tsv;",
		'      for file in *.txt; do',
		'        run_ssake.pl $file > /dev/null &',
		'      done',
		'      wait',
		"\n      awk 'length(\$0)>1' *.ssake.asm.out > ssake.fa;",
		'      md5sum ssake.fa > ssake.fa.md5;',
		'    fi',
		'    if [ ! -s ssake.sam.md5 ]; then',
		"      echo '>> aligning fasta reads...'",
		"      bwa mem -t $args{n_cpus} -M $bwa_ref ssake.fa > ssake.sam;",
		'      md5sum ssake.sam > ssake.sam.md5;',
		'      if [ -s ssake.sam.md5 ]; then',
		'        rm bp_reads.tsv;',
		"        rm {0..$cpu_count}.txt*;",
		'        rm ssake.fa;',
		'      fi',
		'    fi',
		'  fi'
		);

	return($part1_command);
	}

# format command to infer breakpoints
sub get_infer_breakpoints_command {
	my %args = (
		output_file	=> undef,
		tumour_bam	=> undef,
		normal_bam	=> undef,
		n_cpus		=> 1,
		@_
		);

	my $nb_output = $args{output_file};

	my $part2_command = join("\n",
		"  if [ ! -s ssake.pass.vcf ] && [ ! -s $nb_output.md5 ]; then",
		"    echo '>> infer structural variants from ssake.sam ...'",
		'    infer_sv.pl ssake.sam > ssake.vcf',
		"    grep -v '^#' ssake.vcf | sed 's/|/\t/g' | sed 's/read//' |  awk '{ if (!x[\$1\$2]) { y[\$1\$2]=\$14; x[\$1\$2]=\$0 } else { if (\$14 > y[\$1\$2]) { y[\$1\$2]=\$14; x[\$1\$2]=\$0 }}} END { for (i in x) { print x[i]}}' | sort -k1,1 -k2,2n | perl -ne 'if (/TRA/) { print } elsif (/SVLEN=(\\d+)/) { if (\$1 > 100) { print \$_ }} elsif (/SVLEN=-(\\d+)/) { if (\$1 > 100 ) { print }}' > ssake.pass.vcf",
		'  fi',
		"  if [ -s ssake.pass.vcf ] && [ ! -s $nb_output.md5 ]; then",
		"    echo '>> infer breakpoints for SVs...'",
		'    num=$(wc -l ssake.pass.vcf | cut -f1 -d' . "' ');",
		'    rec=$(echo $num/' . $args{n_cpus} . ' | bc);',
		'    rec=$((rec+1));',
		'    split -l $rec ssake.pass.vcf',
		'    for file in x??; do',
		'      infer_bp_v4.pl $file '. "$args{tumour_bam} $args{normal_bam}" . ' > $file.sp.vcf & ',
		'    done',
		'    wait',
		"    echo '>> filter SVs...'",
		"\n" . "    grep '^#' ssake.vcf > header.txt;",
		'    filter_sv_icgc.pl *.sp.vcf | cat header.txt - > ' . $nb_output . ';',
		"    md5sum $nb_output > $nb_output.md5;",
		"    if [ -s $nb_output.md5 ]; then",
		'      rm ssake.{sam,vcf,pass.vcf};',
		'      rm x??;',
		'      rm x??.sp.vcf;',
		'    fi',
		'  fi'
		);

	return($part2_command);
	}

# format command to process novoBreak output
sub get_process_novobreak_command {
	my %args = (
		tumour_id	=> undef,
		tumour_bam	=> undef,
		normal_bam	=> undef,
		nb_file		=> undef,
		tmp_dir		=> undef,
		n_cpus		=> 1,
		@_
		);

	my $part1_command = "cd $args{tmp_dir}\n";

	# part 1
	$part1_command .= "\n" . join("\n",
		'if [ -s ssake.sam.md5 ]; then',
		"  echo 'Intermediate output file: ssake.sam already exists';",
		'else',
		"  echo 'Extracting and aligning reads...';"
		);

	$part1_command .= "\n" . get_prep_ssake_command(
		output_file	=> $args{nb_file},
		n_cpus		=> $args{n_cpus}
		);

	$part1_command .= "\nfi";

	# part 2
	my $final_output = join('/', $args{tmp_dir}, '..', $args{tumour_id} . '_novoBreak.pass.vcf');

	my $part2_command .= "\n\n" . join("\n",
		"if [ -s $final_output.md5 ]; then",
		"  echo 'Final output file " . $args{tumour_id} . "_novoBreak.pass.vcf already exists';",
		'else',
		"  echo 'Inferring variants and breakpoints...';"
		);

	$part2_command .= "\n" . get_infer_breakpoints_command(
		output_file	=> $final_output,
		tumour_bam	=> $args{tumour_bam},
		normal_bam	=> $args{normal_bam},
		n_cpus		=> $args{n_cpus}
		);

	$part2_command .= "\nfi";

	my $final_command = $part1_command . "\n" . $part2_command;

	return($final_command);
	}

# format command to filter variants
sub get_filter_command {
	my %args = (
		sample_dir	=> undef,
		output_file	=> undef,
		tumour_id	=> undef,
		normal_id	=> undef,
		@_
		);

	my $nb_output = join('/', $args{sample_dir}, $args{tumour_id} . '_novoBreak.pass.vcf');
	my $sorted_file = join('/', $args{sample_dir}, $args{tumour_id} . '_novoBreak.pass_sorted.vcf');

	my $filter_command = join(' ',
		'vcf-sort -c', $nb_output,
		'>', $sorted_file
		);

	$filter_command .= "\n\n" . join(' ',
		"perl $cwd/filter_novobreak_variants.pl",
		'-v', $sorted_file,
		'-o', $args{output_file},
		'-t', $args{tumour_id},
		'-n', $args{normal_id},
		'-r', $reference
		);

	$filter_command .= "\n\nmd5sum $args{output_file} > $args{output_file}.md5";
	$filter_command .= "\n\nrm $sorted_file";

	return($filter_command);
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
		print "Initiating NovoBreak pipeline...\n";
		}

	# load tool config
	my $tool_data_orig = LoadFile($tool_config);
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'novobreak');
	my $date = strftime "%F", localtime;

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_NovoBreak_pipeline.log');

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

		$log_file = join('/', $log_directory, 'run_NovoBreak_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";
	$log->autoflush;

	print $log "---\n";
	print $log "Running NovoBreak SV calling pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Reference used: $tool_data->{reference}";

	$reference = $tool_data->{reference};
	$bwa_ref = $tool_data->{bwa}->{reference};

	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---\n";

	# set tools and versions
	my $novobreak	= 'novoBreak/' . $tool_data->{novobreak_version};
	my $samtools	= 'samtools/' . $tool_data->{samtools_version};
	my $vcftools	= 'vcftools/' . $tool_data->{vcftools_version};
	my $bwa		= 'bwa/' . $tool_data->{bwa_version};
	my $r_version	= 'R/' . $tool_data->{r_version};

	# get user-specified tool parameters
	my $parameters = $tool_data->{novobreak}->{parameters};

	# get optional HPC group
	my $hpc_group = defined($tool_data->{hpc_group}) ? "-A $tool_data->{hpc_group}" : undef;

	### RUN ###########################################################################################
	my ($run_script, $run_id, $link, $chr_file, $cleanup_run_id, $ref_dir);
	my (@all_jobs);

	# get sample data
	my $smp_data = LoadFile($data_config);

	unless($args{dry_run}) {
		print "Processing " . scalar(keys %{$smp_data}) . " patients.\n";
		}

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient";

		# find bams
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};

		if (scalar(@normal_ids) == 0) {
			print $log "\n>> No normal BAM provided, skipping patient.\n";
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

		# create an array to hold final outputs and all patient job ids
		my (@final_outputs, @patient_jobs);

		# for T/N pair
		foreach my $sample (@tumour_ids) {

			print $log "  SAMPLE: $sample\n\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			my $tmp_directory = join('/', $sample_directory, 'TEMP');
			unless(-e $tmp_directory) { make_path($tmp_directory); }

			# indicate this should be removed at the end
			my $cleanup_cmd = "rm -rf $tmp_directory";

			$run_id = '';

			# indicate final output file
			my $filtered_output = join('/', $sample_directory, $sample . '_novoBreak_filtered.vcf');

			# run novoBreak using full BAMs
			my $nb_output = join('/', $tmp_directory, $sample . '_nb_kmer.out');

			my $full_novo_command = get_novobreak_command(
				tumour_id	=> $sample,
				tumour_bam	=> $smp_data->{$patient}->{tumour}->{$sample},
				normal_bam	=> $smp_data->{$patient}->{normal}->{$normal_ids[0]},
				out_dir		=> $tmp_directory
				);

			if ( ('Y' eq missing_file("$nb_output.md5")) && ('Y' eq missing_file("$filtered_output.md5")) ) {

				# record command (in log directory) and then run job
				print $log "Submitting job for NovoBreak...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_novobreak_' . $sample,
					cmd	=> $full_novo_command,
					modules	=> [$samtools, $novobreak, 'perl'],
					max_time	=> $parameters->{novobreak}->{time},
					mem		=> $parameters->{novobreak}->{mem},
					cpus_per_task	=> $parameters->{novobreak}->{n_cpu},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_novobreak_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				} else {
				print $log "Skipping NovoBreak because step is already complete!\n";
				}

			# run post-process steps on full novoBreak output
			my $final_nb_output = join('/',
				$sample_directory,
				$sample . '_novoBreak.pass.vcf'
				);

			my $group_reads_command = get_group_by_reads_command(
				nb_file		=> $nb_output,
				directory	=> $tmp_directory
				);

			if ( ('Y' eq missing_file($tmp_directory . '/bp_reads.tsv')) &
				 ('Y' eq missing_file($final_nb_output . '.md5')) ) {
			
				# record command (in log directory) and then run job
				print $log "Submitting job for NovoBreak GroupByReads...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_novobreak_group_reads_' . $sample,
					cmd	=> $group_reads_command,
					modules	=> [$samtools, $novobreak, 'perl'],
					dependencies	=> $run_id,
					max_time	=> $parameters->{group_reads}->{time},
					mem		=> $parameters->{group_reads}->{mem},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_novobreak_group_reads_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				} else {
				print $log "Skipping GroupByReads step as this is already complete!\n";
				}

			my $nb_process_command = get_process_novobreak_command(
				tumour_id	=> $sample,
				tumour_bam	=> $smp_data->{$patient}->{tumour}->{$sample},
				normal_bam	=> $smp_data->{$patient}->{normal}->{$normal_ids[0]},
				nb_file		=> $nb_output,
				tmp_dir		=> $tmp_directory,
				n_cpus		=> $parameters->{postprocess}->{n_cpus}
				);

			if ('Y' eq missing_file($final_nb_output . '.md5')) {
			
				# record command (in log directory) and then run job
				print $log "Submitting job for NovoBreak post-process...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_novobreak_postprocess_' . $sample,
					cmd	=> $nb_process_command,
					modules	=> [$samtools, $novobreak, $bwa, 'perl'],
					dependencies	=> $run_id,
					max_time	=> $parameters->{postprocess}->{time},
					mem		=> $parameters->{postprocess}->{mem},
					cpus_per_task	=> $parameters->{postprocess}->{n_cpus},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_novobreak_postprocess_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				} else {
				print $log "Skipping post-process step as this is already complete!\n";
				}

			# sort and filter output
			$cleanup_cmd .= "\nrm " . join('/',
				$sample_directory,
				$sample . '_novoBreak.pass_sorted.vcf;'
				);

			my $filter_command = get_filter_command(
				sample_dir	=> $sample_directory,
				output_file	=> $filtered_output,
				tumour_id	=> $sample,
				normal_id	=> $normal_ids[0]
				);

			if ('Y' eq missing_file($filtered_output . '.md5')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for FILTER step...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_sort_and_filter_' . $sample,
					cmd	=> $filter_command,
					modules	=> ['perl', $vcftools],
					dependencies	=> $run_id,
					max_time	=> $parameters->{filter}->{time},
					mem		=> $parameters->{filter}->{mem},
					hpc_driver	=> $args{hpc_driver},
					extra_args	=> [$hpc_group]
					);

				$run_id = submit_job(
					jobname		=> 'run_sort_and_filter_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				} else {
				print $log "Skipping final filter step as this is already completed!\n";
				}

			push @final_outputs, $filtered_output;

			# should intermediate files be removed
			# run per patient
			if ($args{del_intermediates}) {

				if ( (scalar(@patient_jobs) == 0) && (! $args{dry_run}) ) {
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
						kill_on_error	=> 0,
						extra_args	=> [$hpc_group]
						);

					$cleanup_run_id = submit_job(
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
