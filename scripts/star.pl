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
require "$cwd/utilities.pl";

####################################################################################################
# version       author	  	comment
# 1.0		sprokopec       script to run STAR alignment on RNASeq data
# 1.1		sprokopec	minor updates for compatibility with larger pipeline
# 1.2		sprokopec	added help message and cleaned up code

### USAGE ##########################################################################################
# star.pl -t tool_config.yaml -d data_config.yaml -o /path/to/output/dir -c slurm --remove --dry_run
#
# where:
#	-t (tool_config.yaml) contains tool versions and parameters, reference information, etc.
#	-d (data_config.yaml) contains sample information (YAML file containing paths to FASTQ files)
#	-o (/path/to/output/dir) indicates tool-specific output directory
#	-b (/path/to/output/yaml) indicates YAML containing processed BAMs
#	-c indicates hpc driver (ie, slurm)
#	--remove remove intermediate files?
#	--dry_run is this a dry run?

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
		tool_config		=> undef,
		data_config		=> undef,
		output_directory	=> undef,
		output_config		=> undef,
		hpc_driver		=> undef,
		del_intermediates	=> undef,
		dry_run			=> undef,
		project			=> undef,
		@_
		);

	my $tool_config = $args{tool_config};
	my $data_config = $args{data_config};

	### PREAMBLE ######################################################################################

	# load tool config
	my $tool_data_orig = LoadFile($tool_config);
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'star');

	# deal with extra arguments
	$args{hpc_driver} = $args{hpc_driver};
	$args{del_intermediates} = $args{del_intermediates};
	$args{dry_run} = $args{dry_run};

	# organize output and log directories
	my $output_directory = $args{output_directory};
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_STAR_pipeline.log');

	# create a file to hold job metrics
	my (@files, $run_count, $outfile, $touch_exit_status);
	unless ($args{dry_run}) {
		# initiate a file to hold job metrics (ensures that an existing file isn't overwritten by concurrent jobs)
		opendir(LOGFILES, $log_directory) or die "Cannot open $log_directory";
		@files = grep { /slurm_job_metrics/ } readdir(LOGFILES);
		$run_count = scalar(@files) + 1;
		closedir(LOGFILES);

		$outfile = $log_directory . '/slurm_job_metrics_' . $run_count . '.out';
		$touch_exit_status = system("touch $outfile");
		if (0 != $touch_exit_status) { Carp::croak("Cannot touch file $outfile"); }

		$log_file = join('/', $log_directory, 'run_STAR_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";

	print $log "---\n";
	print $log "Running STAR alignment pipeline.\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    STAR reference directory: $tool_data->{reference_dir}";
	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---";

	# set tools and versions
	my $star_version	= 'STAR/' . $tool_data->{tool_version};
	my $samtools		= 'samtools/' . $tool_data->{samtools_version};
	my $picard		= 'picard/' . $tool_data->{picard_version};
	my $rnaseqc		= 'rna_seqc/' . $tool_data->{rna_seqc_version};
	my $r_version		= 'R/' . $tool_data->{r_version};

	### MAIN ###########################################################################################
	# get sample data
	my $smp_data = LoadFile($data_config);

	my ($run_script, $run_id);
	my @all_jobs;

	# initiate final output yaml file
	my $output_yaml = $args{output_config};
	open (my $yaml, '>', $output_yaml) or die "Cannot open '$output_yaml' !";
	print $yaml "---\n";

	# create sample sheet (tab-delim file with id/path/group)
	my $qc_directory = join('/', $output_directory, 'RNASeQC_', $run_count);
	unless ( -e $qc_directory ) { make_path($qc_directory); }

	my $sample_sheet = join('/', $qc_directory, 'sample_sheet.tsv');
	open(my $fh, '>', $sample_sheet) or die "Cannot open '$sample_sheet' !";

	# add header
	print $fh "SampleID\tLocation\tGroup\n";

	# process each sample in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient\n";
		print $yaml "$patient:\n";

		my $patient_directory = join('/', $output_directory, $patient);
		unless(-e $patient_directory) { make_path($patient_directory); }

		my $cleanup_cmd = '';
		my (@final_outputs, @patient_jobs);

		my (%tumours, %normals);

		foreach my $sample (sort keys %{$smp_data->{$patient}}) {

			print $log "  SAMPLE: $sample\n";

			# determine sample type
			my $type = $smp_data->{$patient}->{$sample}->{type};

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

				print $log "    LANE: $lane\n";

				# collect input files
				my $r1 = $smp_data->{$patient}->{$sample}->{runlanes}->{$lane}->{R1};
				my $r2 = $smp_data->{$patient}->{$sample}->{runlanes}->{$lane}->{R2};

				print $log "      R1: $r1\n";
				print $log "      R2: $r2\n\n";

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
				`rm -rf $temp_star`;
				}

			$star .= get_star_command_devel(
				r1		=> join(',', @r1_fastqs),
				r2		=> join(',', @r2_fastqs),
				reference_dir	=> $tool_data->{reference_dir},
				readgroup	=> $readgroup,
				tmp_dir		=> $temp_star
				);

			# check if this should be run
			if (
				('Y' eq missing_file(join('/', $sample_directory, 'Aligned.sortedByCoord.out.bam'))) || 
			 	('Y' eq missing_file(join('/', $sample_directory, 'Aligned.toTranscriptome.out.bam')))
				) {
				# record command (in log directory) and then run job
				print $log "Submitting job to run STAR...\n";
				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_STAR_' . $sample,
					cmd	=> $star,
					modules	=> [$star_version],
					dependencies	=> $run_id,
					max_time	=> $tool_data->{parameters}->{star}->{time},
					mem		=> $tool_data->{parameters}->{star}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				# initial test took 15 hours with 22G and 1 node
				$run_id = submit_job(
					jobname		=>'run_STAR_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				}
			else {
				print $log "Skipping alignment step because output already exists...\n";
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
	
			if ('normal' eq $type) { $normals{$sample} = $dedup_bam; }
			if ('tumour' eq $type) { $tumours{$sample} = $dedup_bam; }

			# check if this should be run
			if ('Y' eq missing_file($dedup_bam . '.md5')) {

				$markdup_cmd .= "\n" . join("\n",
					"samtools quickcheck $dedup_bam",
					);

				# record command (in log directory) and then run job
				print $log "Submitting job to merge lanes and mark dupilcates...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_MarkDups_' . $sample,
					cmd	=> $markdup_cmd,
					modules	=> [$picard, $samtools],
					dependencies	=> $run_id,
					max_time	=> $tool_data->{parameters}->{markdup}->{time},
					mem		=> $tool_data->{parameters}->{markdup}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_MarkDups_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @patient_jobs, $run_id;
				push @all_jobs, $run_id;
				}
			else {
				print $log "Skipping mark duplicate step because output already exists...\n";
				}

			push @final_outputs, $dedup_bam;
			}

		# and finally, add the final files to the output yaml
		my $key;
		if (scalar(keys %tumours) > 0) {
			print $yaml "    tumour:\n";
			foreach $key (keys %tumours) { print $yaml "        $key: $tumours{$key}\n"; }
			}
		if (scalar(keys %normals) > 0) {
			print $yaml "    normal:\n";
			foreach $key (keys %normals) { print $yaml "        $key: $normals{$key}\n"; }
			}

		# once per patient, run cleanup
		if ( ($args{del_intermediates}) && (scalar(@patient_jobs) > 0) ) {

			print $log "Submitting job to clean up temporary/intermediate files...\n";

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

		print $log "\nFINAL OUTPUT:\n" . join("\n  ", @final_outputs) . "\n";
		print $log "---\n";
		}

	close $yaml;
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
	print $log "\nSubmitting job for RNA-SeQC...\n";

	$run_script = write_script(
		log_dir	=> $log_directory,
		name	=> 'run_rna_seqc_cohort',
		cmd	=> $qc_cmd,
		modules	=> [$rnaseqc],
		dependencies	=> join(',', @all_jobs),
		max_time	=> $tool_data->{parameters}->{rna_seqc}->{time},
		mem		=> $tool_data->{parameters}->{rna_seqc}->{mem},
		hpc_driver	=> $args{hpc_driver}
		);

	$run_id = submit_job(
		jobname		=> 'run_rna_seqc_cohort',
		shell_command	=> $run_script,
		hpc_driver	=> $args{hpc_driver},
		dry_run		=> $args{dry_run},
		log_file	=> $log
		);

	push @all_jobs, $run_id;

	# collect and combine results
	my $collect_results = join(' ',
		"Rscript $cwd/collect_rnaseqc_output.R",
		'-d', $output_directory,
		'-p', $args{project}
		);

	$run_script = write_script(
		log_dir	=> $log_directory,
		name	=> 'combine_and_format_qc_results',
		cmd	=> $collect_results,
		modules		=> [$r_version],
		dependencies	=> $run_id,
		max_time	=> $tool_data->{parameters}->{combine_results}->{time},
		mem		=> $tool_data->{parameters}->{combine_results}->{mem},
		hpc_driver	=> $args{hpc_driver}
		);

	$run_id = submit_job(
		jobname		=> 'combine_and_format_qc_results',
		shell_command	=> $run_script,
		hpc_driver	=> $args{hpc_driver},
		dry_run		=> $args{dry_run},
		log_file	=> $log
		);

	# if this is not a dry run, collect job metrics (exit status, mem, run time)
	unless ($args{dry_run}) {

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

		# print the final job id to stdout to be collected by the master pipeline
		print $run_id;
		} else {
		print '000000';
		}

	# finish up
	print $log "\nProgramming terminated successfully.\n\n";
	close $log;
	}

### GETOPTS AND DEFAULT VALUES #####################################################################
# declare variables
my ($data_config, $tool_config, $output_directory, $project_name, $output_config);
my $hpc_driver = 'slurm';
my ($remove_junk, $dry_run);

my $help;

# read in command line arguments
GetOptions(
	'h|help'	=> \$help,
	'd|data=s'	=> \$data_config,
	'o|out_dir=s'	=> \$output_directory,
	'b|out_yaml=s'	=> \$output_config,
	't|tool=s'	=> \$tool_config,
	'c|cluster=s'	=> \$hpc_driver,
	'remove'	=> \$remove_junk,
	'p|project=s'	=> \$project_name,
	'dry_run'	=> \$dry_run
	 );

if ($help) {
	my $help_msg = join("\n",
		"Options:",
		"\t--help|-h\tPrint this help message",
		"\t--data|-d\t<string> data config (yaml format)",
		"\t--tool|-t\t<string> tool config (yaml format)",
		"\t--out_dir|-o\t<string> path to output directory",
		"\t--out_yaml|-b\t<string> path to output yaml (listing BWA-aligned BAMs)",
		"\t--cluster|-c\t<string> cluster scheduler (default: slurm)",
		"\t--remove\t<boolean> should intermediates be removed? (default: false)",
		"\t--dry_run\t<boolean> should jobs be submitted? (default: false)"
		);

	print $help_msg;
	exit;
	}

if (!defined($tool_config)) { die("No tool config file defined; please provide -t | --tool (ie, tool_config.yaml)"); }
if (!defined($data_config)) { die("No data config file defined; please provide -d | --data (ie, sample_config.yaml)"); }
if (!defined($output_directory)) { die("No output directory defined; please provide -o | --out_dir"); }

main(
	tool_config		=> $tool_config,
	data_config		=> $data_config,
	output_directory	=> $output_directory,
	output_config		=> $output_config,
	hpc_driver		=> $hpc_driver,
	del_intermediates	=> $remove_junk,
	project			=> $project_name,
	dry_run			=> $dry_run
	);
