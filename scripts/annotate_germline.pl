#!/usr/bin/env perl
### annotate_germline.pl ###########################################################################
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
our ($reference, $ref_type, $cpsr_version);

####################################################################################################
# version	author		comment
# 1.0		sprokopec	script to annotate germline variants

### USAGE ##########################################################################################
# annotate_germline.pl -t tool.yaml -d data.yaml -o /path/to/output/dir -i /path/to/input/dir -c slurm --remove --dry_run
#
# where:
#	-t (tool.yaml) contains tool versions and parameters, reference information, etc.
#	-d (data.yaml) contains sample information (YAML file containing paths to BWA-aligned,
#	GATK-processed BAMs, generated by gatk.pl)
#	-o (/path/to/output/dir) indicates tool-specific output directory
#	-i (/path/to/input/dir) currently uses files generated by genotype_gvcfs.pl
#	-c indicates hpc driver (ie, slurm)
#	--remove indicates that intermediates will be removed
#	--dry_run indicates that this is a dry run

### DEFINE SUBROUTINES #############################################################################
# format command to filter variants
sub create_prepare_vcf_command {
	my %args = (
		input		=> undef,
		sample_id	=> undef,
		output		=> undef,
		tmp_dir		=> undef,
		java_mem	=> undef,
		@_
		);

	my $filter_command = join(' ',
		'java -Xmx' . $args{java_mem},
		'-Djava.io.tmpdir=' . $args{tmp_dir},
		'-jar $gatk_dir/GenomeAnalysisTK.jar -T SelectVariants',
		'-R', $reference,
		'-V', $args{input},
		'-sn', $args{sample_id},
		'--maxIndelSize 1000', #'--max-indel-size 1000',
		'--excludeNonVariants',
		'-o', $args{output}
		);

	return($filter_command);
	}

# format command to run CPSR annotation
sub create_annotate_command {
	my %args = (
		vcf		=> undef,
		sample_id	=> undef,
		output_dir	=> undef,
		ref_type	=> undef,
		@_
		);

	my $cpsr_command .= "\n\n" . join(' ',
		"cpsr.py",
		'--query_vcf', $args{vcf},
		'--pcgr_dir /' ,
		'--output_dir', $args{output_dir},
		'--panel_id 1',
		'--conf /usr/local/bin/cpsr.toml',
		'--secondary_findings --classify_all --force_overwrite',
		'--maf_upper_threshold 0.2 --no_vcf_validate --no-docker',
		'--genome_assembly', $args{ref_type},
		'--sample_id', $args{sample_id}
		);

	return($cpsr_command);
	}

# format command to extract significant hits
sub create_extract_command {
	my %args = (
		tier_files	=> undef,
		input_vcf	=> undef,
		output_vcf	=> undef,
		tmp_dir		=> undef,
		known_positions => undef,
		@_
		);

	my $extract_command = "cd $args{tmp_dir}";

	$extract_command .= "\n\n" . join(' ',
		'cat', $args{tier_files},
		"| grep -v 'GENOMIC_CHANGE'",
		'| awk -F"\t"', "'\$81 >= 0' | cut -f1 | uniq",
		'| perl -e', "'while(<>) { \$_ =~ m/(^[0-9XY]):g.([0-9]+)/;",
		'print join("\t", "chr" . $1, $2) . "\n" }', "'",
		'> cpsr_significant.txt'
		);

	$extract_command .= "\n\n" . join(' ',
		'cat', $args{known_positions}, 'cpsr_significant.txt',
		"| cut -f1,2 | grep -v 'Chromosome'",
		'> keep_positions.txt'
		);

	if ($args{input_vcf} =~ m/gz$/) {
		$extract_command .= "\n\nvcftools --gzvcf $args{input_vcf}";
		} else {
		$extract_command .= "\n\nvcftools --vcf $args{input_vcf}";
		}

	$extract_command .= ' ' . join(' ',
		'--positions keep_positions.txt --stdout --recode',
		'>', $args{output_vcf}
		);

	return($extract_command);
	}

### MAIN ###########################################################################################
sub main{
	my %args = (
		tool_config		=> undef,
		data_config		=> undef,
		output_directory	=> undef,
		input_directory		=> undef,
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
	my $tool_data = error_checking(tool_data => $tool_data_orig, pipeline => 'vep');

	# organize directories
	my $input_directory = $args{input_directory};
	my $output_directory = $args{output_directory};
	$input_directory =~ s/\/$//;
	$output_directory =~ s/\/$//;

	my $log_directory = join('/', $output_directory, 'logs', 'RUN_ANNOTATE_GERMLINE');
	unless(-e $log_directory) { make_path($log_directory); }

	my $log_file = join('/', $log_directory, 'run_CPSR_pipeline.log');

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

		$log_file = join('/', $log_directory, 'run_CPSR_pipeline_' . $run_count . '.log');
		}

	# start logging
	open (my $log, '>', $log_file) or die "Could not open $log_file for writing.";
	$log->autoflush;

	print $log "---\n";
	print $log "Running ANNOTATE Germline SNV/INDEL pipeline...\n";
	print $log "\n  Tool config used: $tool_config";
	print $log "\n    Reference: $tool_data->{reference}";

	$reference = $tool_data->{reference};

	if ('hg19' eq $tool_data->{ref_type}) {
		$ref_type = 'grch37';
		} elsif ('hg38' eq $tool_data->{ref_type}) { $ref_type = 'grch38'; }

	my $known_positions = $tool_data->{haplotype_caller}->{parameters}->{cpsr}->{known_positions};
	print $log "\n   Using known variants: $known_positions";

	print $log "\n    Output directory: $output_directory";
	print $log "\n  Sample config used: $data_config";
	print $log "\n---\n\n";

	# set tools and versions
	my $gatk	= 'gatk/' . $tool_data->{gatk_version};
	my $samtools	= 'samtools/' . $tool_data->{samtools_version};
	my $vcftools	= 'vcftools/' . $tool_data->{vcftools_version};
	my $r_version	= 'R/' . $tool_data->{r_version};

	my $pcgr	= 'pcgr/' . $tool_data->{pcgr_version};
#	$cpsr_version	= $tool_data->{cpsr_version};

	# get user-specified tool parameters
	my $parameters = $tool_data->{haplotype_caller}->{parameters};

	### RUN ###########################################################################################
	# get sample data
	my $smp_data = LoadFile($data_config);

	my ($run_script, $cleanup_cmd, $run_id);
	my @all_jobs;

	# set up some directories
	my $annotate_directory = join('/', $output_directory, 'CPSR');
	unless (-e $annotate_directory) { make_path($annotate_directory); }

	# First step, find all of the GenotypeGVCF output files
	opendir(HC_OUTPUT, $input_directory) or die "Could not open $input_directory";
	my @filtered_gvcfs = grep { /variants.vcf$|variants.vcf.gz$/ } readdir(HC_OUTPUT);
	closedir(HC_OUTPUT);

	# process each patient in $smp_data
	foreach my $patient (sort keys %{$smp_data}) {

		print $log "\nInitiating process for PATIENT: $patient\n";

		my @patient_vcfs = grep { /$patient/ } @filtered_gvcfs;
		if (scalar(@patient_vcfs) == 0) {
			print $log "\n>> No filtered gvcf found; skipping patient.\n\n";
			next;
			}
		my $patient_vcf = join('/', $input_directory, $patient_vcfs[0]);

		# make some directories
		my $patient_directory = join('/', $annotate_directory, $patient);
		unless (-e $patient_directory) { make_path($patient_directory); }

		my $tmp_directory = join('/', $patient_directory, 'TEMP');
		unless (-e $tmp_directory) { make_path($tmp_directory); }

		$cleanup_cmd .= "rm -rf $tmp_directory\n";

		# find sample IDs
		my @normal_ids = keys %{$smp_data->{$patient}->{'normal'}};
		my @tumour_ids = keys %{$smp_data->{$patient}->{'tumour'}};

		my @sample_ids;
		push @sample_ids, @normal_ids;
		push @sample_ids, @tumour_ids;

		# create an array to hold final outputs and job id
		my (@final_outputs, @patient_jobs, @tier_files);

		# loop over each sample
		foreach my $sample ( @sample_ids ) {

			$run_id = '';

			print $log "  SAMPLE: $sample\n\n";

			# make some directories
			my $sample_directory = join('/', $patient_directory, $sample);
			unless (-e $sample_directory) { make_path($sample_directory); }

			# run select variants to remove large INDELs and select this sample
			my $subset_vcf = join('/',
				$tmp_directory,
				$sample . '_Germline_filtered.vcf'
				);

			my $prepare_vcf_cmd = create_prepare_vcf_command(
				input		=> $patient_vcf,
				sample_id	=> $sample,
				output		=> $subset_vcf,
				tmp_dir		=> $tmp_directory,
				java_mem	=> '256M'
				);

			if ('Y' eq missing_file($subset_vcf . '.idx')) {

				# record command (in log directory) and then run job
				print $log "Submitting job for SelectVariants...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_select_variants_' . $sample,
					cmd	=> $prepare_vcf_cmd,
					modules	=> [$gatk],
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_select_variants_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @all_jobs, $run_id;
				push @patient_jobs, $run_id;
				} else {
				print $log "Skipping SelectVariants because this is already done!\n";
				}

			# run CPSR annotation
			my $annotate_cmd = create_annotate_command(
				vcf		=> $subset_vcf,
				sample_id	=> $sample,
				output_dir	=> $sample_directory,
				ref_type	=> $ref_type
				);

			my $annotate_final = join('/',
				$sample_directory,
				join('.', $sample, 'cpsr', $ref_type, 'snvs_indels.tiers.tsv')
				);

			push @tier_files, $annotate_final;

			if ('Y' eq missing_file($annotate_final)) {

				# record command (in log directory) and then run job
				print $log "Submitting job for CPSR...\n";

				$run_script = write_script(
					log_dir	=> $log_directory,
					name	=> 'run_cpsr_and_pcgr_' . $sample,
					cmd	=> $annotate_cmd,
					modules => ['perl', $pcgr],
					dependencies	=> $run_id,
					max_time	=> $parameters->{cpsr}->{time},
					mem		=> $parameters->{cpsr}->{mem},
					hpc_driver	=> $args{hpc_driver}
					);

				$run_id = submit_job(
					jobname		=> 'run_cpsr_and_pcgr_' . $sample,
					shell_command	=> $run_script,
					hpc_driver	=> $args{hpc_driver},
					dry_run		=> $args{dry_run},
					log_file	=> $log
					);

				push @all_jobs, $run_id;
				push @patient_jobs, $run_id;
				} else {
				print $log "Skipping CPSR because this is already done!\n";
				}
			}

		# extract 
		my $filtered_vcf = join('/',
			$tmp_directory,
			$patient . '_significant_hits.vcf'
			);

		my $filter_cmd = create_extract_command(
			tier_files	=> join(' ', @tier_files),
			input_vcf	=> $patient_vcf,
			output_vcf	=> $filtered_vcf,
			tmp_dir		=> $tmp_directory,
			known_positions	=> $known_positions
			);

		if ('Y' eq missing_file($filtered_vcf)) {

			# record command (in log directory) and then run job
			print $log "Submitting job for filter step...\n";

			$run_script = write_script(
				log_dir	=> $log_directory,
				name	=> 'run_vcf_filter_' . $patient,
				cmd	=> $filter_cmd,
				modules => [$vcftools],
				dependencies	=> join(':', @patient_jobs),
				hpc_driver	=> $args{hpc_driver}
				);

			$run_id = submit_job(
				jobname		=> 'run_vcf_filter_' . $patient,
				shell_command	=> $run_script,
				hpc_driver	=> $args{hpc_driver},
				dry_run		=> $args{dry_run},
				log_file	=> $log
				);

			push @all_jobs, $run_id;
			push @patient_jobs, $run_id;
			} else {
			print $log "Skipping filter step because this is already done!\n";
			}

		# loop over each tumour sample
		foreach my $sample ( @tumour_ids ) {

			my $sample_directory = join('/', $patient_directory, $sample);

			my $output_stem = join('/',
				$sample_directory,
				join('_', $sample, 'CPSR', 'germline_hc')
				);

			### Run variant annotation (VEP + vcf2maf)
			my $final_vcf = $output_stem . ".vep.vcf";
			my $final_maf = $output_stem . ".maf";

			my $vcf2maf_cmd = get_vcf2maf_command(
				input		=> $filtered_vcf,
				tumour_id	=> $sample,
				normal_id	=> $normal_ids[0],
				reference	=> $reference,
				ref_type	=> $tool_data->{ref_type},
				output		=> $final_maf,
				tmp_dir		=> $sample_directory,
				vcf2maf		=> $tool_data->{annotate}->{vcf2maf_path},
				vep_path	=> $tool_data->{annotate}->{vep_path},
				vep_data	=> $tool_data->{annotate}->{vep_data},
				filter_vcf	=> $tool_data->{annotate}->{filter_vcf}
				);

			# check if this should be run
			if ('Y' eq missing_file($final_maf . '.md5')) {

				my $vep_vcf = join('/',
					$sample_directory,
					$patient . '_significant_hits.vep.vcf'
					);

				if ('N' eq missing_file($vep_vcf)) {
					`rm $vep_vcf`;
					}

				# IF THIS FINAL STEP IS SUCCESSFULLY RUN,
				$vcf2maf_cmd .= "\n\n" . join("\n",
					"if [ -s $final_maf ]; then",
					"  md5sum $final_maf > $final_maf.md5",
					"  mv $vep_vcf $final_vcf",
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

		print $log "\nFINAL OUTPUT:\n" . join("\n  ", @final_outputs) . "\n";
		print $log "---\n";
		}

	# collate results
	my $collect_output = join(' ',
		"Rscript $cwd/collect_snv_output.R",
		'-d', $annotate_directory,
		'-p', $tool_data->{project_name}
		);

	$run_script = write_script(
		log_dir	=> $log_directory,
		name	=> 'combine_significant_variants',
		cmd	=> $collect_output,
		modules	=> [$r_version],
		dependencies	=> join(':', @all_jobs),
		mem		=> '1G',
		max_time	=> '12:00:00',
		hpc_driver	=> $args{hpc_driver}
		);

	$run_id = submit_job(
		jobname		=> 'combine_significant_variants',,
		shell_command	=> $run_script,
		hpc_driver	=> $args{hpc_driver},
		dry_run		=> $args{dry_run},
		log_file	=> $log
		);

	# should intermediate files be removed?
	if ($args{del_intermediates}) {

		print $log "Submitting job to clean up temporary/intermediate files...\n";

		$run_script = write_script(
			log_dir	=> $log_directory,
			name	=> 'run_cleanup_cohort',
			cmd	=> $cleanup_cmd,
			dependencies	=> join(':', @all_jobs),
			mem		=> '256M',
			hpc_driver	=> $args{hpc_driver},
			kill_on_error	=> 0
			);

		$run_id = submit_job(
			jobname		=> 'run_cleanup_cohort',
			shell_command	=> $run_script,
			hpc_driver	=> $args{hpc_driver},
			dry_run		=> $args{dry_run},
			log_file	=> $log
			);
		}

	# if this is not a dry run OR there are jobs to assess (run or resumed with jobs submitted) then
	# collect job metrics (exit status, mem, run time)
	unless ( ($args{dry_run}) || (scalar(@all_jobs) == 0) ) {

		# collect job stats
		my $collect_metrics = collect_job_stats(
			job_ids => join(',', @all_jobs),
			outfile => $outfile
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
					die("Final GenotypeGVCFs accounting job: $run_id finished with errors.");
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
my ($data_config, $tool_config, $output_directory, $input_directory);
my $hpc_driver = 'slurm';
my ($remove_junk, $dry_run, $help, $no_wait);

# get command line arguments
GetOptions(
	'h|help'	=> \$help,
	't|tool=s'	=> \$tool_config,
	'd|data=s'	=> \$data_config,
	'o|out_dir=s'	=> \$output_directory,
	'i|in_dir=s'	=> \$input_directory,
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
		"\t--in_dir|-i\t<string> path to input directory",
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
if (!defined($data_config)) { die("No data config file defined; please provide -d | --data (ie, data_config.yaml)"); }
if (!defined($output_directory)) { die("No output directory defined; please provide -o | --out_dir"); }

main(
	tool_config		=> $tool_config,
	data_config		=> $data_config,
	output_directory	=> $output_directory,
	input_directory		=> $input_directory,
	hpc_driver		=> $hpc_driver,
	del_intermediates	=> $remove_junk,
	dry_run			=> $dry_run,
	no_wait			=> $no_wait
	);
