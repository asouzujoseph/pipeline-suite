#!/usr/bin/env perl
### star.pl ########################################################################################
use AutoLoader 'AUTOLOAD';
use strict;
use warnings;
use Carp;
use POSIX qw(strftime);
use Getopt::Std;
use Getopt::Long;
use File::Basename;
use File::Path qw(make_path);
use YAML qw(LoadFile);

my $cwd = dirname($0);
require "$cwd/shared/utilities.pl";

####################################################################################################
# version       author	  	comment
# 1.1		sprokopec       script to run STAR alignment on RNASeq data

### USAGE ##########################################################################################
# star.pl -t tool_config.yaml -c data_config.yaml
#
# where:
#	- tool_config.yaml contains tool versions and parameters, output directory,
#	reference information, etc.
#	- data_config.yaml contains sample information (YAML file containing paths to FASTQ files,
#	generated by create_fastq_yaml.pl)

### SUBROUTINES ####################################################################################
# format command to run alignment using STAR
sub get_star_command {
	my %args = (
		r1		=> undef,
		r2		=> undef,
		reference_dir	=> undef,
		tmp_dir		=> undef,
		@_
		);

	my $star_command = join(' ',
		'STAR --runMode alignReads',
		'--genomeDir', $args{reference_dir},
		'--readFilesCommand zcat',
		'--readFilesIn', $args{r1}, $args{r2},
		'--runThreadN 1',
		'--genomeSAsparseD 2',
		'--twopassMode Basic',
		'--outSAMprimaryFlag AllBestScore',
		'--outFilterIntronMotifs RemoveNoncanonical',
		'--outSAMtype BAM SortedByCoordinate',
		'--chimSegmentMin 10',
		'--chimOutType SeparateSAMold',
		'--quantMode GeneCounts TranscriptomeSAM',
		'--limitIObufferSize 250000000',
		'--limitBAMsortRAM 29000000000',
		'--outTmpDir', $args{tmp_dir},
		'--outSAMunmapped Within',
		'--outBAMsortingThreadN 1'
		);

	return($star_command);
	}

sub get_star_command_devel {
	my %args = (
		r1		=> undef,
		r2		=> undef,
		reference_dir	=> undef,
		readgroup	=> undef,
		tmp_dir		=> undef,
		@_
		);

	my $star_command = join(' ',
		'STAR --runMode alignReads',
		# basic options
		'--genomeDir', $args{reference_dir},
		'--runThreadN 1',
		'--readFilesCommand zcat',
		'--readFilesIn', $args{r1}, $args{r2},
		'--twopassMode Basic',
		# output options
	#	'--outFileNamePrefix', $stem,
		'--outTmpDir', $args{tmp_dir},
		'--outSAMtype BAM SortedByCoordinate',
		'--outSAMunmapped Within',
		'--outSAMprimaryFlag AllBestScore',
		'--outBAMsortingThreadN 1',
		'--outFilterIntronMotifs RemoveNoncanonical',
		# Note: --chimOutType SeparateSAMold has been deprecated; as of the new version of STAR (2.7.2), these are the recommended args:
		# https://github.com/STAR-Fusion/STAR-Fusion/wiki
		'--chimSegmentMin 10',
	#	'--chimOutType WithinBAM',
		'--chimJunctionOverhangMin 10',
		'--chimOutJunctionFormat 1',
		'--alignSJDBoverhangMin 10',
		'--alignMatesGapMax 100000',
		'--alignIntronMax 100000',
		'--alignSJstitchMismatchNmax 5 -1 5 5',
		'--outSAMattrRGline', $args{readgroup},
		'--chimMultimapScoreRange 3',
		'--chimScoreJunctionNonGTAG -4',
		'--chimMultimapNmax 20',
		'--chimNonchimScoreDropMin 10',
		'--peOverlapNbasesMin 12',
		'--peOverlapMMp 0.1',
		# transcript quant mode
		'--quantMode GeneCounts TranscriptomeSAM',
		# limit options
		'--limitIObufferSize 250000000',
		'--limitBAMsortRAM 29000000000'
		);

	return($star_command);
	}

# format command to add readgroup and sort BAM
sub format_readgroup {
	my %args = (
		subject		=> undef,
		sample		=> undef,
		lane		=> undef,
		lib		=> undef,
		platform	=> 'Illumina',
		@_
		);

	my $readgroup = "ID:patient\tSM:smp\tPL:platform\tPU:unit\tLB:library";
	$readgroup =~ s/patient/$args{subject}/;
	$readgroup =~ s/smp/$args{sample}/;
	$readgroup =~ s/unit/$args{lane}/;
	$readgroup =~ s/library/$args{lib}/;
	$readgroup =~ s/platform/$args{platform}/;

	return($readgroup);
	}

# format command to mark duplicates
sub get_markdup_command {
	my %args = (
		input		=> undef,
		output		=> undef,
		java_mem	=> undef,
		tmp_dir		=> undef,
		@_
		);

	my $markdup_command = join(' ',
		'java -Xmx' . $args{java_mem},
		'-Djava.io.tmpdir=' . $args{tmp_dir},
		'-jar $picard_dir/picard.jar MarkDuplicates',
		'INPUT=' . $args{input},
		'OUTPUT=' . $args{output},
		'METRICS_FILE=' . $args{output} . '.metrics',
		'ASSUME_SORTED=true CREATE_INDEX=true CREATE_MD5_FILE=true',
		'MAX_RECORDS_IN_RAM=100000 VALIDATION_STRINGENCY=SILENT'
		);

	return($markdup_command);
	}

# format command to run RNA-SeQC
sub get_rnaseqc_cmd {
	my %args = (
		input		=> undef,
		output_dir	=> undef,
		bwa		=> '/cluster/tools/software/bwa/0.7.15/',
		reference	=> undef,
		gtf		=> undef,
		java_mem	=> undef,
		tmp_dir		=> undef,
		@_
		);

	my $qc_command = join(' ',
		'java -Xmx' . $args{java_mem},
		'-Djava.io.tmpdir=' . $args{tmp_dir},
		'-jar $rnaseqc_dir/RNA-SeQC.jar',
		'-bwa', $args{bwa},
		'-o', $args{output_dir},
		'-t', $args{gtf},
		'-r', $args{reference},
		'-singleEnd no',
		'-s', $args{input}
		);

	return($qc_command);
	}

### MAIN ###########################################################################################
sub main {
	my %args = (
		tool_config	=> undef,
		data_config	=> undef,
		@_
		);

	my $tool_config = $args{tool_config};
	my $data_config = $args{data_config};

	### PREAMBLE ######################################################################################

	# load tool config
	my $tool_data_orig = LoadFile($tool_config);
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'star');
	$tool_data->{date} = strftime "%F", localtime;

	# check for resume and confirm output directories
	my ($resume, $output_directory, $log_directory) = set_output_path(tool_data => $tool_data);

	# start logging
	print "---\n";
	print "Running STAR alignment pipeline.\n";
	print "\n  Tool config used: $tool_config";
	print "\n    STAR reference directory: $tool_data->{reference_dir}";
	print "\n    Output directory: $output_directory";
	print "\n  Sample config used: $data_config";
	print "\n---";

	# set tools and versions
	my $star_version	= 'STAR/' . $tool_data->{tool_version};
	my $samtools		= 'samtools/' . $tool_data->{samtools_version};
	my $picard		= 'picard/' . $tool_data->{picard_version};
	my $rnaseqc		= 'rna_seqc/' . $tool_data->{rna_seqc_version};

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

	### MAIN ###########################################################################################
	# get sample data
	my $smp_data = LoadFile($data_config);

	my ($run_script, $run_id);
	my @all_jobs;

	# create sample sheet (tab-delim file with id/path/group)
	my $qc_directory = join('/', $output_directory, 'RNASeQC');
	unless ( -e $qc_directory ) { make_path($qc_directory); }

	my $sample_sheet = join('/', $qc_directory, 'sample_sheet.tsv');
	open(my $fh, '>', $sample_sheet) or die "Cannot open '$sample_sheet' !";

	# add header
	print $fh "SampleID\tLocation\tGroup\n";

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print "\nInitiating process for PATIENT: $patient\n";

		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my $cleanup_cmd = '';
		my (@final_outputs, @patient_jobs);

		foreach my $sample (sort keys %{$smp_data->{$patient}}) {

			print "  SAMPLE: $sample\n";

			my $sample_directory = join('/', $patient_directory, $sample);
			unless(-e $sample_directory) { make_path($sample_directory); }

			my $raw_directory = join('/', $sample_directory, 'fastq_links');
			unless(-e $raw_directory) { make_path($raw_directory); }

			my $temp_star = join('/', $sample_directory, 'intermediate_files');
			$cleanup_cmd .= "rm -rf $temp_star";

			my $tmp_directory = join('/', $sample_directory, 'TEMP');
			unless(-e $tmp_directory) { make_path($tmp_directory); }
			$cleanup_cmd .= "; rm -rf $tmp_directory";

			my @lanes = keys %{$smp_data->{$patient}->{$sample}->{runlanes}};
			my (@r1_fastqs, @r2_fastqs);

			foreach my $lane ( @lanes ) {

				print "    LANE: $lane\n";

				# collect input files
				my $r1 = $smp_data->{$patient}->{$sample}->{runlanes}->{$lane}->{R1};
				my $r2 = $smp_data->{$patient}->{$sample}->{runlanes}->{$lane}->{R2};

				print "      R1: $r1\n";
				print "      R2: $r2\n\n";

				my @tmp = split /\//, $r1;
				my $raw_link = join('/', $raw_directory, $tmp[-1]);
				symlink($r1, $raw_link);
				$raw_link =~ s/R1/R2/;
				symlink($r2, $raw_link);

				# add to respective lists
				push @r1_fastqs, $r1;
				push @r2_fastqs, $r2;
				}

			# clear out run_id for this sample
			$run_id = '';

			## run STAR on these fastqs
			my $readgroup = format_readgroup(
				subject		=> $patient,
				sample		=> $sample,
				lane		=> join(',', @lanes),
				lib		=> $sample,
				platform	=> $tool_data->{platform}
				);

			my $star = "cd $sample_directory\n";

			if ( -e $temp_star ) {
				$star .= "rm -rf $temp_star\n";
				}

			$star .= get_star_command_devel(
				r1		=> join(',', @r1_fastqs),
				r2		=> join(',', @r2_fastqs),
				reference_dir	=> $tool_data->{reference_dir},
				readgroup	=> $readgroup,
				tmp_dir		=> $temp_star
				);

			# check if this should be run
			if ( ('N' eq $resume) ||
				(
					('Y' eq missing_file(join('/', $sample_directory, 'Aligned.sortedByCoord.out.bam'))) || 
					('Y' eq missing_file(join('/', $sample_directory, 'Aligned.toTranscriptome.out.bam')))
					)
				) {
				# record command (in log directory) and then run job
				print "Submitting job to run STAR...\n";
				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_STAR_' . $sample,
					cmd	=> $star,
					modules	=> [$star_version],
					dependencies	=> $run_id,
					max_time	=> $tool_data->{parameters}->{star}->{time},
					mem		=> $tool_data->{parameters}->{star}->{mem},
					hpc_driver	=> $tool_data->{HPC_driver}
					);

				# initial test took 15 hours with 22G and 1 node
				$run_id = submit_job(
					jobname		=>'run_STAR_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $tool_data->{HPC_driver},
					dry_run		=> $tool_data->{dry_run}
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				}
			else {
				print "Skipping alignment step because output already exists...\n";
				}
		
			## mark duplicates
			my $input_file = join('/', $sample_directory, '/Aligned.sortedByCoord.out.bam');
			my $dedup_bam = join('/', $patient_directory, $sample . '_sorted_markdup.bam');

			print $fh "$sample\t$dedup_bam\tRNASeq\n";

			my $markdup_cmd = get_markdup_command(
				input		=> $input_file,
				output		=> $dedup_bam,
				java_mem	=> $tool_data->{parameters}->{markdup}->{java_mem},
				tmp_dir		=> $tmp_directory
				);

			# check if this should be run
			if ( ('N' eq $resume) || ('Y' eq missing_file($dedup_bam . '.md5')) ) {

				# IF THIS FINAL STEP IS SUCCESSFULLY RUN,
				# create a symlink for the final output in the TOP directory
				my @final = split /\//, $dedup_bam;
                                my $final_link = join('/', $tool_data->{output_dir}, $final[-1]);

				if (-l $final_link) {
					unlink $final_link or die "Failed to remove previous symlink: $final_link;\n";
					}

				my $link_cmd = "ln -s $dedup_bam $final_link";

				# this is a java-based command, so run a final check
				my $java_check = check_java_output(
					extra_cmd	=> $link_cmd
					);

				$markdup_cmd .= "\n" . join("\n",
					"samtools quickcheck $dedup_bam",
					$java_check
					);

				# record command (in log directory) and then run job
				print "Submitting job to merge lanes and mark dupilcates...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_MarkDups_' . $sample,
					cmd	=> $markdup_cmd,
					modules	=> [$picard, $samtools],
					dependencies	=> $run_id,
					max_time	=> $tool_data->{parameters}->{markdup}->{time},
					mem		=> $tool_data->{parameters}->{markdup}->{mem},
					hpc_driver	=> $tool_data->{HPC_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_MarkDups_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $tool_data->{HPC_driver},
					dry_run		=> $tool_data->{dry_run}
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				}
			else {
				print "Skipping mark duplicate step because output already exists...\n";
				}

			push @final_outputs, $dedup_bam;
			}

		# once per patient, run cleanup
		if ( ('Y' eq $tool_data->{del_intermediate}) && (scalar(@patient_jobs) > 0) ) {

			print "Submitting job to clean up temporary/intermediate files...\n";

			# make sure final output exists before removing intermediate files!
			$cleanup_cmd = join("\n",
				"if [ -s " . join(" ] && [ -s ", @final_outputs) . " ]; then",
				$cleanup_cmd,
				"else",
				'echo "One or more FINAL OUTPUT FILES is missing; not removing intermediates"',
				"fi"
				);

			# if all lane alignments + mark dup are successful, clean up tmp directories
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

	close $fh;

	# get command for RNASeQC
	my $qc_cmd = get_rnaseqc_cmd(
		input		=> $sample_sheet,
		output_dir	=> $qc_directory,
		bwa		=> $tool_data->{parameters}->{rna_seqc}->{bwa_path},
		reference	=> $tool_data->{parameters}->{rna_seqc}->{reference},
		gtf		=> $tool_data->{parameters}->{rna_seqc}->{reference_gtf},
		java_mem	=> $tool_data->{parameters}->{rna_seqc}->{java_mem},
		tmp_dir		=> $qc_directory
		);

	$qc_cmd .= ";\n\ncd $qc_directory;";
	$qc_cmd .= "\nif [ -s metrics.tsv ]; then";
	$qc_cmd .= "\n  find . -name '*tmp.txt*' -exec rm {} ". '\;';
	$qc_cmd .= "\nfi";

	# record command (in log directory) and then run job
	print "\nSubmitting job for RNA-SeQC...\n";

	$run_script = write_script(
		log_dir	=> $log_directory,
		name	=> 'run_rna_seqc_cohort',
		cmd	=> $qc_cmd,
		modules	=> [$rnaseqc],
		dependencies	=> join(',', @all_jobs),
		max_time	=> $tool_data->{parameters}->{rna_seqc}->{time},
		mem		=> $tool_data->{parameters}->{rna_seqc}->{mem},
		hpc_driver	=> $tool_data->{HPC_driver}
		);

	$run_id = submit_job(
		jobname		=> 'run_rna_seqc_cohort',
		shell_command	=> $run_script,
		hpc_driver	=> $tool_data->{HPC_driver},
		dry_run		=> $tool_data->{dry_run}
		);

	push @all_jobs, $run_id;

	# if this is not a dry run, collect job metrics (exit status, mem, run time)
	if ('N' eq $tool_data->{dry_run}) {

		# collect job metrics
		my $collect_metrics = collect_job_stats(
			job_ids => join(',', @all_jobs),
			outfile => $outfile
			);

		$run_script = write_script(
			log_dir => $log_directory,
			name    => 'output_job_metrics_' . $run_count,
			cmd     => $collect_metrics,
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

		print "Creating config yaml for output BAM files...\n";

		my $output_yaml_cmd = join(' ',
			"perl $cwd/shared/create_final_yaml.pl",
			'-d', $output_directory,
			'-o', $output_directory . '/bam_config.yaml',
			'-p', 'markdup.bam$'
			);

		$run_script = write_script(
			log_dir => $log_directory,
			name    => 'output_final_yaml',
			cmd     => $output_yaml_cmd,
			modules => ['perl'],
			dependencies	=> join(',', @all_jobs),
			max_time	=> '0:10:00',
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

# read in command line arguments
GetOptions(
	't|tool=s'      => \$tool_config,
	'c|config=s'    => \$data_config
	 );

if (!defined($tool_config)) { die("No tool config file defined; please provide -t | --tool (ie, tool_config.yaml)"); }
if (!defined($data_config)) { die("No data config file defined; please provide -c | --config (ie, sample_config.yaml)"); }

main(tool_config => $tool_config, data_config => $data_config);
