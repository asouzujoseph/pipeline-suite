#!/usr/bin/env perl
### write_wxs_methods.pl ###########################################################################
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

my $cwd = dirname($0);
require "$cwd/../utilities.pl";

####################################################################################################
# version       author		comment
# 1.0		sprokopec       tool to automatically generate reports

### MAIN ###########################################################################################
sub main {
	my %args = (
		config		=> undef,
		directory	=> undef,
		@_
		);

	my $tool_data = LoadFile($args{config});

	### RUN ####################################################################################
	# for each tool (indicated in config file), read in and extract parameters
	my $methods = "\\section{Methods}\n";
	$methods .= "For all tools, default parameters were used unless otherwise indicated.\\newline\n";
	$methods .= "\\subsection{Alignment and Quality Checks:}\n";

	my ($bwa, $gatk, $mutect, $mutect2, $strelka, $manta, $varscan, $delly, $mavis);
	my ($ref_type, $samtools, $picard, $intervals, $bedtools, $vcftools, $bcftools);
	my ($k1000g, $mills, $kindels, $dbsnp, $hapmap, $omni, $cosmic);
	my ($vep, $vcf2maf);

	# how was BWA run?
	if ('Y' eq $tool_data->{bwa}->{run}) {

		$bwa		= $tool_data->{bwa_version};
		$samtools	= $tool_data->{samtools_version};
		$picard		= $tool_data->{picard_version};
		$ref_type	= $tool_data->{ref_type};

		$methods .= "Fastq files were aligned to $ref_type using the BWA-MEM algorithm (v$bwa), with -M. Resulting SAM files were coordinate sorted, converted to BAM format and indexed using using samtools (v$samtools).";

		if ('Y' eq $tool_data->{bwa}->{parameters}->{merge}->{mark_dup}) {
			$methods .= " Duplicate reads were marked and lane- and library-level BAMs were merged using Picard tools (v$picard).\\newline\n";
			} else {
			$methods .= "Lane- and library-level BAMs were merged using Picard tools (v$picard).\\newline\n";
			}
		$methods .= "\\newline\n";
		} else {
		$methods .= "BWA not run.\\newline\n";
		}

	# how was GATK run?
	if ('Y' eq $tool_data->{gatk}->{run}) {

		$gatk = $tool_data->{gatk_version};
		my @parts = split('\\/', $tool_data->{intervals_bed});
		$intervals = $parts[-1];

		# find reference files
		if ('hg38' eq $tool_data->{ref_type}) {

			$k1000g		= 'hg38bundle/1000G_phase1.snps.high_confidence.hg38.vcf.gz';
			$kindels	= 'hg38bundle/Homo_sapiens_assembly38.known_indels.vcf.gz';
			$mills		= 'hg38bundle/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz';
			$dbsnp		= 'hg38bundle/dbsnp_144.hg38.vcf.gz';

			} elsif ('hg19' eq $tool_data->{ref_type}) {

			$k1000g		= '1000G_phase1.snps.high_confidence.hg19.vcf';
			$kindels	= '1000G_phase1.indels.hg19.vcf';
			$mills		= 'Mills_and_1000G_gold_standard.indels.hg19.vcf';
			$dbsnp		= 'dbsnp_138.hg19.vcf';

			}

		if (defined($tool_data->{dbsnp})) {
			@parts = split('\\/', $tool_data->{dbsnp});
			$dbsnp = $parts[-1];
			}

		$methods .= "Indel realignment and base-quality recalibration were performed for each patient using GATK (v$gatk), with analyses restricted to target regions with interval padding set to 100bp. Known indels were provided for indel realignment and known snps were provided for recalibration. Additional options --disable_auto_index_creation_and_locking_when_reading_rods and -dt None were indicated throughout, -nWayOut for IndelRealigner, options -rf BadCigar, --covariate {ReadGroupCovariate, QualityScoreCovariate, CycleCovariate, ContextCovariate} for BaseRecalibrator and -rf BadCigar for PrintReads.\\newline\n";
		$methods .= join("\n",
			"{\\scriptsize \\begin{itemize}",
			"  \\vspace{-0.2cm}\\item $intervals",
			"  \\vspace{-0.2cm}\\item Known INDELs: $mills",
			"  \\vspace{-0.2cm}\\item Known INDELs: $kindels",
			"  \\vspace{-0.2cm}\\item Known SNPs: $dbsnp",
			"  \\vspace{-0.2cm}\\item Known SNPs: $k1000g",
			"\\end{itemize} }"
			) . "\n";
		} else {
		$methods .= "GATK not run.\\newline\n";
		}

	# how was QC run?
	if ('Y' eq $tool_data->{bamqc}->{run}) {

		my $threshold = '3.0';
		my $t_depth = '20x';
		my $n_depth = '15x';

		$gatk = $tool_data->{gatk_version};
		$bedtools = $tool_data->{bedtools_version};
		my @parts = split('\\/', $tool_data->{hapmap});
		$hapmap = $parts[-1];

		if (defined($tool_data->{bamqc}->{parameters}->{contest}->{threshold})) {
			$threshold = $tool_data->{bamqc}->{parameters}->{contest}->{threshold};
			}

		if (defined($tool_data->{bamqc}->{parameters}->{callable_bases}->{min_depth}->{tumour})) {
			$t_depth = $tool_data->{bamqc}->{parameters}->{callable_bases}->{min_depth}->{tumour};
			$t_depth .= 'x';
			}
		if (defined($tool_data->{bamqc}->{parameters}->{callable_bases}->{min_depth}->{normal})) {
			$n_depth = $tool_data->{bamqc}->{parameters}->{callable_bases}->{min_depth}->{normal};
			$n_depth .= 'x';
			}

		$methods .= "\\noindent\nFor tumours with a matched normal, GATK's implementation of ContEst was used to estimate cross-sample contamination. Population frequencies from hapmap were provided, and --interval_set_rule set to INTERSECTION. Again, target intervals were provided, with interval padding set to 100bp. It is recommended that tumours with a contamination estimate \$>$threshold\\%\$ be excluded from downstream analyses. GATK's DepthOfCoverage was used to assess genome coverage, again on both sample and readgroup levels (with -omitBaseOutput -omitIntervals -omitLocusTable), and callable bases defined as those with a minimum of $t_depth (tumour) or $n_depth (normal) coverage using bedtools (v$bedtools).\\newline\n";
		$methods .= join("\n",
			"{\\scriptsize \\begin{itemize}",
			"  \\vspace{-0.2cm}\\item $hapmap",
			"\\end{itemize} }"
			) . "\n";
		} else {
		$methods .= "BAM quality checks (ContEst, coverage and callable bases) not performed.\\newline\n";
		}

	# how was haplotypecaller run?
	if ('Y' eq $tool_data->{haplotype_caller}->{run}) {

		$methods .= "\\subsection{Germline Variant calling:}\n";

		$gatk = $tool_data->{gatk_version};
		my @parts = split('\\/', $tool_data->{intervals_bed});
		$intervals = $parts[-1];

		# find reference files
		if (defined($tool_data->{dbsnp})) {
			@parts = split('\\/', $tool_data->{dbsnp});
			$dbsnp = $parts[-1];
			} elsif ('hg38' eq $tool_data->{ref_type}) {
			$dbsnp = 'dbsnp_144.hg38.vcf.gz';
			} elsif ('hg19' eq $tool_data->{ref_type}) {
			$dbsnp = 'dbsnp_138.hg19.vcf';
			}

		# find reference files
		if ('hg38' eq $tool_data->{ref_type}) {

			$k1000g	= 'hg38bundle/1000G_phase1.snps.high_confidence.hg38.vcf.gz';
			$hapmap	= 'hg38bundle/hapmap_3.3.hg38.vcf.gz';
			$omni	= 'hg38bundle/1000G_omni2.5.hg38.vcf.gz';
			$mills	= 'hg38bundle/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz';

			} elsif ('hg19' eq $tool_data->{ref_type}) {

			$k1000g	= '1000G_phase1.snps.high_confidence.hg19.vcf';
			$hapmap	= 'hapmap_3.3.hg19.vcf';
			$omni	= '1000G_omni2.5.hg19.vcf';
			$mills	= 'Mills_and_1000G_gold_standard.indels.hg19.vcf';

			}

		$methods .= "Germline variants were identified using GATK's (v$gatk) HaplotypeCaller and GenotypeGVCFs as per GATK's germline variant calling best practices. HaplotypeCaller was run in GVCF mode, using a minimum confidence threshold of 30, variant index type and parameter of LINEAR and 128000. Known variants (dbSNP) were provided, as were target intervals with interval padding set to 100bp. Variants were combined across samples (using CombineGVCFs) and genotyped using GenotypeGVCFs. Variant score recalibration was performed for INDELs and SNPs separately. For INDELs, known indels were provided, and recalibrater run using tranche sensitivity thresholds of 90, 99, 99.9 and 100 percent and maximum 2 Gaussians for the positive model. For SNPs, known snps and dbSNP were provided, and recalibrater run using maximum 4 Gaussians for the positive model. Recalibration was applied using truth sensitivity filter of 99 using the above generated .tranches and .recal files.\\newline\n";
		$methods .= join("\n",
			"{\\scriptsize \\begin{itemize}",
			"  \\vspace{-0.2cm}\\item dbSNP: $dbsnp",
			"  \\vspace{-0.2cm}\\item Target regions: $intervals",
			"  \\vspace{-0.2cm}\\item Known INDELs: $mills", # (known=true,training=true,truth=true,prior=12.0)",
			"  \\vspace{-0.2cm}\\item Known SNPs: $hapmap", # (known=false,training=true,truth=true,prior=15.0)",
			"  \\vspace{-0.2cm}\\item Known SNPs: $omni", # (known=false,training=true,truth=true,prior=12.0)",
			"  \\vspace{-0.2cm}\\item Known SNPs: $k1000g", # (known=false,training=true,truth=false,prior=10.0)",
			"  \\vspace{-0.2cm}\\item Known SNPs: $dbsnp", # (known=true,training=false,truth=false,prior=2.0)",
			"\\end{itemize} }"
			) . "\n";
		} else {
		$methods .= "Germline variants not called.\\newline\n";
		}

	# how were somatic SNVs called?
	$methods .= "\\subsection{Somatic Variant Calling:}\n";

	if ('Y' eq $tool_data->{mutect}->{run}) {

		$mutect		= $tool_data->{mutect_version};
		$gatk		= $tool_data->{gatk_version};
		$vcftools	= $tool_data->{vcftools_version};

		if (defined($tool_data->{dbsnp})) {
			my @parts = split('\\/', $tool_data->{dbsnp});
			$dbsnp = $parts[-1];
			} elsif ('hg38' eq $tool_data->{ref_type}) {
			$dbsnp = 'dbsnp_144.hg38.vcf.gz';
			} elsif ('hg19' eq $tool_data->{ref_type}) {
			$dbsnp = 'dbsnp_138.hg19.vcf';
			}

		if (defined($tool_data->{cosmic})) {
			my @parts = split('\\/', $tool_data->{cosmic});
			$cosmic = $parts[-2];
			}

		# annotation
		my @parts = split('\\/', $tool_data->{annotate}->{vep_path});
		$vep = $parts[-1];
		@parts = split('\\/', $tool_data->{annotate}->{vcf2maf_path});
		$vcf2maf = $parts[-2];

		# fill in methods
		$methods .= "\\subsubsection{MuTect (v$mutect):}\n";
		$methods .= "A panel of normals was produced using all available normal samples, with MuTect's artifact\_detection\_mode. COSMIC ($cosmic; likely somatic [keep]) and dbSNP ($dbsnp; likely germline [remove]) were used as known lists, and variant calling restricted to target regions (\$\\pm 100bp\$). Variants were merged across samples using GATK's CombineVariants (v$gatk), removing any variant that did not pass MuTect and GATK's default quality criteria (FILTER field not equal to PASS), and keeping variants present in at least 2 samples.\\newline\n";
		$methods .= "For somatic calls, MuTect was run on T/N pairs, or tumour-only samples using identical methods. COSMIC ($cosmic; likely somatic [keep]), dbSNP ($dbsnp; likely germline [remove]) and the panel of normals were provided as known lists, and variant calling restricted to target regions (\$\\pm 100bp\$). Lastly, calls were filtered (using vcftools v$vcftools) to again remove any that did not pass MuTect's filter criteria (FILTER did not equal PASS).\\newline\n";
		} else {
		$methods .= "MuTect not run.\\newline\n";
		}

	if ('Y' eq $tool_data->{mutect2}->{run}) {

		$gatk = $tool_data->{gatk_version};
		$vcftools = $tool_data->{vcftools_version};

		if (defined($tool_data->{dbsnp})) {
			my @parts = split('\\/', $tool_data->{dbsnp});
			$dbsnp = $parts[-1];
			} elsif ('hg38' eq $tool_data->{ref_type}) {
			$dbsnp = 'dbsnp_144.hg38.vcf.gz';
			} elsif ('hg19' eq $tool_data->{ref_type}) {
			$dbsnp = 'dbsnp_138.hg19.vcf';
			}

		if (defined($tool_data->{cosmic})) {
			my @parts = split('\\/', $tool_data->{cosmic});
			$cosmic = $parts[-2];
			}

		# annotation
		my @parts = split('\\/', $tool_data->{annotate}->{vep_path});
		$vep = $parts[-1];
		@parts = split('\\/', $tool_data->{annotate}->{vcf2maf_path});
		$vcf2maf = $parts[-2];

		# fill in methods
		$methods .= "\\subsubsection{MuTect2 (GATK v$gatk):}\n";
		$methods .= "A panel of normals was produced using all available normal samples, with MuTect2's artifact\_detection\_mode. dbSNP ($dbsnp; likely germline [remove]) was provided and variant calling restricted to target regions (\$\\pm 100bp\$). Variants were merged across samples using GATK's CombineVariants (v$gatk), removing any variant that did not pass MuTect and GATK's default quality criteria (FILTER field not equal to PASS), and keeping variants present in at least 2 samples.\\newline\n";
		$methods .= "For somatic calls, MuTect2 was run on T/N pairs, or tumour-only samples using identical methods. COSMIC ($cosmic; likely somatic [keep]) , dbSNP ($dbsnp; likely germline [remove]) and the panel of normals were provided as known lists, and variant calling restricted to target regions (\$\\pm 100bp\$). Lastly, calls were filtered (using vcftools v$vcftools) to again remove any that did not pass MuTect2's filter criteria (FILTER did not equal PASS).\\newline\n";
		} else {
		$methods .= "MuTect2 not run.\\newline\n";
		}

	if ('Y' eq $tool_data->{strelka}->{run}) {

		$strelka	= $tool_data->{strelka_version};
		$manta		= $tool_data->{manta_version};
		$gatk		= $tool_data->{gatk_version};
		$vcftools	= $tool_data->{vcftools_version};

		# annotation
		my @parts = split('\\/', $tool_data->{annotate}->{vep_path});
		$vep = $parts[-1];
		@parts = split('\\/', $tool_data->{annotate}->{vcf2maf_path});
		$vcf2maf = $parts[-2];

		# fill in methods
		$methods .= "\\subsubsection{Strelka (v$strelka):}\n";
		$methods .= "Strelka and Manta were run using default parameters in exome mode, with callable regions restricted to target regions.\\newline\n";
		$methods .= "A panel of normals was produced using all available normal samples, using Strelka's germline workflow. Resulting variants were merged across samples using GATK's CombineVariants (v$gatk), removing any variant that did not pass quality criteria (FILTER field not equal to PASS), and keeping variants present in at least 2 samples.\\newline\n";
		$methods .= "For somatic variant detection, Strelka  was run on each sample following the developers recommended protocol. First, Manta (v$manta) was run on each T/N pair or tumour-only sample to identify a set of candidate small indels to be provided to Strelka for use in variant calling. Strelka's somatic workflow was run on T/N pairs, while the germline workflow was used for tumour-only samples. In both cases, resulting variant lists were filtered (using vcftools v$vcftools) to remove likely germline variants (found in the panel of normals) and poor quality calls (FILTER field did not equal PASS).\\newline\n";
		} else {
		$methods .= "Strelka not run.\\newline\n";
		}

	if ('Y' eq $tool_data->{varscan}->{run}) {

		$varscan	= $tool_data->{varscan_version};
		$gatk		= $tool_data->{gatk_version};
		$samtools	= $tool_data->{samtools_version};
		$vcftools	= $tool_data->{vcftools_version};
		if (defined($tool_data->{bcftools_version})) {
			$bcftools = $tool_data->{bcftools_version};
			} else { $bcftools = '1.2-4-g1fedb8b'; }

		# annotation
		my @parts = split('\\/', $tool_data->{annotate}->{vep_path});
		$vep = $parts[-1];
		@parts = split('\\/', $tool_data->{annotate}->{vcf2maf_path});
		$vcf2maf = $parts[-2];

		# fill in methods
		$methods .= "\\subsubsection{VarScan (v$varscan):}\n";
		$methods .= "For variant calling in T/N pairs, samtools (v$samtools) mpileup was run on each T/N pair, using -B -q1 -d 10000 and restricting call regions to target regions. Positions with 0 coverage in both the tumour and normal were excluded and the resulting output provided to VarScan. VarScan somatic and processSomatic were used to generate lists of high-confidence germline and somatic variant positions. VarScan somatic was run again, using --output-vcf, and the resulting VCF was filtered (using bcftools v$bcftools) to produce a high-confidence germline VCF file and a high-confidence somatic VCF file.\\newline\n";
		$methods .= "To produce a panel of normals, high-confidence germline variants were merged across samples using GATK's CombineVariants (v$gatk), removing any variant that did not pass quality criteria (FILTER field not equal to PASS), and keeping variants present in at least 2 samples.\\newline\n";
		$methods .= "For variant calling in tumour-only samples, samtools (v$samtools) mpileup was run, again using -B -q1 -d 10000 and restricting call regions to target regions. Positions with 0 coverage were excluded and the resulting output provided to VarScan mpileup2cns using --output-vcf and --variants. Resulting variants were filtered (using vcftools v$vcftools) to remove germline variants (using the panel of normals).\\newline\n";
		} else {
		$methods .= "VarScan not run.\\newline\n";
		}

	if (defined($vep)) {
		$methods .= "\\subsubsection{Annotation:}\n";
		$methods .= "Somatic short variants (SNVs and INDELs) were filtered and annotated using VEP (v$vep) and vcf2maf (v$vcf2maf). Filters were applied to remove known common variants (ExAC nonTCGA version r1), and variants with low coverage (see callable bases above).\\newline\n";
#		$methods .= "Lastly, SNVs and INDELs detected by 2 or more variant calling tools were deemed high-confidence somatic variants and carried forward for recurrence analyses.\\newline\n";
		} else {
		$methods .= "No somatic variant calling performed.\\newline\n";
		}

	# how were SVs called?
	$methods .= "\\subsection{Structural Variant Calling:}\n";

	if ('Y' eq $tool_data->{delly}->{run}) {

		$delly = $tool_data->{delly_version};
		$bcftools = $tool_data->{bcftools_version};

		# fill in methods
		if (defined($manta)) {
			$methods .= "Somatic structural variants (SVs) including large insertions/deletions, duplications, inversions and translocations were identified using Delly (v$delly) and Manta (v$manta).\\newline\n";
			} else {
			$methods .= "Somatic structural variants (SVs) including large insertions/deletions, duplications, inversions and translocations were identified using Delly (v$delly).\\newline\n";
			}
		$methods .= "\\newline\n";
		$methods .= "Delly was run on each T/N pair or tumour-only sample, with variants filtered (per patient; -m 0 -a 0.1 -r 0.5 -v 10 -p) and merged (cohort; -m 0 -n 250000000 -b 0 -r 1.0) to identify a joint site list. Sites were genotyped in each sample, merged using bcftools (v$bcftools) and finalized (per tumour, filtered against all available normals; -m 0 -a 0.1 -r 0.5 -v 10 -p), according to published best practices.\\newline\n\\newline\n";
		}

	if (defined($manta)) {
		if (!defined($delly)) {
			$methods .= "Somatic structural variants (SVs) including large insertions/deletions, duplications, inversions and translocations were identified using Manta (v$manta).\\newline\n\\newline\n";
			}
		$methods .= "Manta was run on each T/N pair or tumour-only sample, using the --exome setting and --callRegions to restrict calls to target intervals.\\newline\n\\newline\n";
		} elsif ( (!defined($manta)) && (!defined($delly)) ) {
		$methods .= "No structural variant calling performed or this was performed outside of the present pipeline.\\newline\n";
		}

	if ('Y' eq $tool_data->{mavis}->{run}) {
		$ref_type	= $tool_data->{ref_type};
		$mavis		= $tool_data->{mavis_version};

		$methods .= "Mavis (v$mavis) was run once for each patient, using available SV calls, with the $ref_type reference files provided by the developers. BWA was indicated as the aligner, with the bwa-indexed reference file as above.\\newline\n\\newline\n";
		} else {
		$methods .= "Mavis not run.\\newline\n";
		}

	if (defined($varscan)) {
		$methods .= "Somatic copy-number aberrations (SCNAs) were identified using VarScan (v$varscan) and Sequenza (v2.1; R v3.3.0). VarScan was run as above on T/N pairs, using the copynumber and copyCaller tools.\\newline\n";
		} else {
		$methods .= "VarScan and Sequenza not run to detect SCNAs.\\newline\n";
		}

	# clean up special characters
	$methods =~ s/_/\\_/g;

	# write methods to file
	open(my $methods_file, '>', $args{directory} . "/methods.tex");
	print $methods_file <<EOI;
$methods
EOI
	close($methods_file);

	}
 
### GETOPTS AND DEFAULT VALUES #####################################################################
# declare variables
my ($help, $config, $directory);

# get command line arguments
GetOptions(
	'h|help'	=> \$help,
	't|tool=s'	=> \$config,
	'd|directory=s'	=> \$directory
	);

if ($help) {
	my $help_msg = join("\n",
		"Options:",
		"\t--help|-h\tPrint this help message",
		"\t--tool|-t\t<string> Master config file for the DNA pipeline",
		"\t--directory|-d\t<string> path to output directory",
		) . "\n";

	print $help_msg;
	exit;
	}

# do some quick error checks to confirm valid arguments	
main(config => $config, directory => $directory);