#!/usr/bin/perl
#David Parry January 2014
use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use Term::ProgressBar;
use Data::Dumper;
use FindBin;
use lib "$FindBin::Bin";
use ParseVCF;
use SortGenomicCoordinates;
use ParsePedfile;

my $genotype_quality = 20;
my $vcf;
my @samples;
my @reject;
my @reject_except;
my @head;
my @classes;
my $reject;
my $identical_genotypes;
my $allow_missing;
my @add;
my $list_genes = 0;#will change to '' if user specifies --list but provides no argument, in which case print to STDERR
my $out;
my @damaging = ();#missense prediction programs (SIFT, polyphen, condel) to use for filtering missense variants
my $keep_any_damaging;#default is that all scores from programs specified in @damaging must be 'damaging'
my $filter_unpredicted; #ignore missense variants that don't have a score for programs used in @damaging -NOT IMPLEMENTED YET!
my $canonical_only; #canonical transcripts only
my $pass_filters; #only keep variants with PASS filter field.
my $gmaf;#filter GMAF if present if equal to or above this value (0.0 - 0.5)
my $any_maf;#filter MAF if present if equal to or above this value in any population
my $help;
my $man;
my $progress;
my $check_all_samples;
my $homozygous_only;
my $splice_consensus = 0; #use this flag to check for SpliceConsensus VEP plugin annotations
my $pedigree;

my %opts = (
            'input' => \$vcf,
            'output' => \$out,
            'list' => \$list_genes,
            'samples' => \@samples,
            'reject' => \@reject,
            'reject_all_except' => \@reject_except,
            'family' => \$pedigree,
            'classes' => \@classes,
            'canonical_only' => \$canonical_only,
            'pass_filters' => \$pass_filters,
            'damaging' => \@damaging,
            'keep_any_damaging' => \$keep_any_damaging,
            'unpredicted_missense' => \$filter_unpredicted,
            'gmaf' => \$gmaf, 
            'maf' => \$any_maf, 
            'check_all_samples' => \$check_all_samples,
            'equal_genotypes' => \$identical_genotypes,
            'quality' => \$genotype_quality,
            #'allow_missing_genotypes' => \$allow_missing,
            'progress' => \$progress,
            'add_classes' => \@add,
            'homozygous_only' => \$homozygous_only,
            'consensus_splice_site' => \$splice_consensus,
            'help' => \$help,
            'manual' => \$man);
GetOptions(\%opts,
            'input=s',
            'output=s',
            'list:s',
            'samples=s{,}',
            'r|reject=s{,}' => \@reject,
            'x|reject_all_except:s{,}' => \@reject_except,
            'family=s',
            'classes=s{,}',
            'canonical_only',
            'pass_filters',
            'damaging=s{,}',
            'keep_any_damaging',
            'unpredicted_missense',
            'gmaf=f', 
            'maf=f', 
            'check_all_samples',
            'equal_genotypes',
            'quality=i',
#           'allow_missing_genotypes',
            'progress',
            'add_classes=s{,}',
            'homozygous_only',
            'consensus_splice_site',
            'help',
            'manual' => ,
            )
        or pod2usage(-message => "Syntax error", exitval => 2);

pod2usage(-verbose => 2) if $man;
pod2usage(-verbose => 1) if $help;
pod2usage(-message => "Syntax error: input is required.", exitval => 2) if not $vcf;
pod2usage(-message => "Syntax error: please specify samples to analyze using --samples (-s), --check_all_samples or --family (-f) arguments.", exitval => 2) if not @samples and not $check_all_samples and not $pedigree;
pod2usage(-message => "--gmaf option requires a value between 0.00 and 0.50 to filter on global minor allele frequency.\n", -exitval => 2) if (defined $gmaf && ($gmaf < 0 or $gmaf > 0.5));

#QUICKLY CHECK PEDIGREE BEFORE DEALING WITH POTENTIALLY HUGE VCF
my $ped;
if ($pedigree){
    $ped  = ParsePedfile->new(file => $pedigree);
    #die "Pedigree file must contain at least one affected member!\n" if not $ped->getAllAffecteds();
}

#SORT OUT VEP DETAILS
my @valid = qw (transcript_ablation
        splice_donor_variant
        splice_acceptor_variant
        stop_gained
        frameshift_variant
        stop_lost
        initiator_codon_variant
        inframe_insertion
        inframe_deletion
        missense_variant
        transcript_amplification
        splice_region_variant
        incomplete_terminal_codon_variant
        synonymous_variant
        stop_retained_variant
        coding_sequence_variant
        mature_miRNA_variant
        5_prime_UTR_variant
        3_prime_UTR_variant
        intron_variant
        NMD_transcript_variant
        non_coding_exon_variant
        nc_transcript_variant
        upstream_gene_variant
        downstream_gene_variant
        TFBS_ablation
        TFBS_amplification
        TF_binding_site_variant
        regulatory_region_variant
        regulatory_region_ablation
        regulatory_region_amplification
        feature_elongation
        feature_truncation
        intergenic_variant);

if (not @classes){
    #@classes = qw(missense nonsense stoploss deletion insertion splicing splice_consensus);
    @classes = qw (transcript_ablation
        splice_donor_variant
        splice_acceptor_variant
        stop_gained
        frameshift_variant
        stop_lost
        initiator_codon_variant
        inframe_insertion
        inframe_deletion
        missense_variant
        transcript_amplification
        TFBS_ablation
        TFBS_amplification
        regulatory_region_ablation
        regulatory_region_amplification);
}
push (@classes, @add) if (@add);
push @classes, "splice_region_variant" if $splice_consensus;
foreach my $class (@classes){
    die "Error - variant class '$class' not recognised.\n" if not grep {/$class/i} @valid;
}
my @csq_fields = qw (allele gene feature feature_type consequence hgnc);#default fields to retrieve from CSQ INFO field
my %allelic_genes; #record transcript id as key to anon hash with sample as key, and number of mutations as value 
my %geneline; #store lines here
my %id_to_symbol;#hash of transcript id to gene symbol
my %listing = ();#hash of gene symbols with values being arrays of transcript IDs - persistent

my %damage_filters = (); #hash of prediction program names and values to filter

if (@damaging){
    my %valid_damaging = (sift => ["deleterious", "tolerated"],  polyphen => ["probably_damaging", "possibly_damaging", "benign", "unknown"], condel => ["deleterious", "neutral"]);
    my %default_damaging = (sift => ["deleterious", ],  polyphen => ["probably_damaging", "possibly_damaging",], condel => ["deleterious", ]);
    foreach my $d (@damaging){
        my ($prog, $label) = split("=", $d);
        if (exists $valid_damaging{lc$prog}){
            push @csq_fields, lc($prog);
            no warnings 'uninitialized';
            my @filters = add_damaging_filters(lc$prog, lc$label, \%valid_damaging, \%default_damaging);
            push @{$damage_filters{lc$prog}}, @filters;
        }elsif (lc($prog) eq 'all'){
            %damage_filters = %default_damaging;
            push @csq_fields, qw(sift polyphen condel);
        }else{ 
            die "Unrecognised value ($d) passed to --damaging argument. See --help for more info.\n";
        }
    }
}else{    
    if ($keep_any_damaging and $filter_unpredicted){
        die "--keep_any_damaging and --unpredicted_missense arguments can only be used when --damaging argument is in effect.\n";
    }elsif ($keep_any_damaging){
        die "--keep_any_damaging argument can only be used when --damaging argument is in effect.\n";
    }elsif ($filter_unpredicted){
        die "--unpredicted_missense argument can only be used when --damaging argument is in effect.\n";
    }
}
        

if ($canonical_only){
    push @csq_fields, 'canonical';
}

if (defined $gmaf or defined $any_maf){
        push @csq_fields, 'gmaf';
}
if ($splice_consensus){
    push @csq_fields, 'splice_consensus';
}

#PARSED VEP ARGUMENTS
#INITIALIZE VCF

print STDERR "Initializing VCF input ($vcf)...\n";
my $vcf_obj = ParseVCF->new(file=> $vcf);
print STDERR "Checking VCF is sorted...\n";
if (not $vcf_obj->checkCoordinateSorted()){
    die "Vcf input is not sorted in coordinate order - please sort your input and try again.\n";
}
#CHECK VEP ARGUMENTS AGAINST VCF
my $vep_header = $vcf_obj->readVepHeader();
my @available_mafs = ();
if (defined $any_maf){
    foreach my $key (keys %{$vep_header}){
        if ($key =~ /\w_MAF$/){
            push @available_mafs, $key;
            push @csq_fields, $key;
        }
    }
}
if (@csq_fields > 1){
    my %seen = ();
    @csq_fields = grep { ! $seen{$_}++ } @csq_fields;
}
my $replace_hgnc = 0;
foreach my $c (@csq_fields){
    if (not exists $vep_header->{$c}){
        if ($c eq 'hgnc'){
            if (not exists $vep_header->{'symbol'}){#they've awkwardly replaced hgnc with symbol in v73 and above
            die "Couldn't find 'hgnc' or 'symbol' VEP field in header - please ensure your VCF is annotated with " .
            "Ensembl's variant effect precictor specifying the appropriate annotations.\n";
            }else{
                $replace_hgnc++;
            }
        }else{
            die "Couldn't find '$c' VEP field in header - please ensure your VCF is annotated with " .
            "Ensembl's variant effect precictor specifying the appropriate annotations.\n";
        }
    }
}

if ($replace_hgnc){
    @csq_fields = grep {!/^hgnc$/} @csq_fields;
    push @csq_fields, 'symbol';
}

#DONE CHECKING VEP INFO
#CHECK OUR SAMPLES/PEDIGREE INFO
if ($check_all_samples){
    push @samples, $vcf_obj->getSampleNames();
}
if($ped){
    my @aff = ();
    my @un = ();
    my @not_aff = ();
    my @not_un = ();
    foreach my $s ($ped->getAllAffecteds()){
        if ($vcf_obj->checkSampleInVcf($s)){
            push @aff, $s;
        }else{
            push @not_aff, $s;
        }
    }
    foreach my $s ($ped->getAllUnaffecteds()){
        if ($vcf_obj->checkSampleInVcf($s)){
            push @un, $s;
        }else{
            push @not_un, $s;
        }
    }
    print STDERR "Found " .scalar(@aff) . " affected samples from pedigree in VCF.\n";
    print STDERR scalar(@not_aff) . " affected samples from pedigree were not in VCF.\n";
    print STDERR "Found " .scalar(@un) . " unaffected samples from pedigree in VCF.\n";
    print STDERR scalar(@not_un) . " unaffected samples from pedigree were not in VCF.\n";
    push @samples, @aff;
    push @reject, @un;
}
#check @samples and @reject exist in file
my @not_found = ();
foreach my $s (@samples, @reject){
    if (not $vcf_obj->checkSampleInVcf($s)){
        push @not_found, $s;
    }
    if (@not_found){
        die "Could not find the following samples in VCF:\n".join("\n", @not_found)."\n";
    }
}
die "No affected samples found in VCF\n" if not @samples;

if (@reject_except){
    my @all = $vcf_obj->getSampleNames();
    push @reject_except, @samples; 
    my %subtract = map {$_ => undef} @reject_except;
    @all = grep {!exists $subtract{$_} } @all;
    push @reject, @all;
}

#remove any duplicate samples in @samples or @reject
my %seen = ();
@reject = grep { ! $seen{$_}++} @reject;
%seen = ();
@samples = grep { ! $seen{$_}++} @samples;
%seen = ();
#make sure no samples appear in both @samples and @reject
my %dup = map {$_ => undef} @samples;
foreach my $s (@samples){
    my @doubles = grep {exists ($dup{$_}) } @reject;
    die "Same sample(s) specified as both affected and unaffected:\n" .join("\n",@doubles) ."\n" 
        if @doubles;
}

#DONE CHECKING SAMPLE INFO
#SET UP OUR OUTPUT FILES

my $OUT;
if ($out){
    open ($OUT, ">$out") || die "Can't open $out for writing: $!\n";
}else{
    $OUT = \*STDOUT;
}
my $LIST;
if ($list_genes){
    open ($LIST, ">$list_genes") || die "Can't open $list_genes for writing: $!\n";
}elsif($list_genes eq '' ){#user specified --list option but provided no argument
    $LIST = \*STDERR;
    $list_genes = 1;
}

print $OUT  $vcf_obj->getHeader(0) ."##findBiallelicVep.pl\"";
my @opt_string = ();
foreach my $k (sort keys %opts){
    if (not ref $opts{$k}){
        push @opt_string, "$k=$opts{$k}";
    }elsif (ref $opts{$k} eq 'SCALAR'){
        if (defined ${$opts{$k}}){
            push @opt_string, "$k=${$opts{$k}}";
        }else{
            push @opt_string, "$k=undef";
        }
    }elsif (ref $opts{$k} eq 'ARRAY'){
        if (@{$opts{$k}}){
            push @opt_string, "$k=" .join(",", @{$opts{$k}});
        }else{
            push @opt_string, "$k=undef";
        }
    }
}
print $OUT join(" ", @opt_string) . "\"\n" .  $vcf_obj->getHeader(1);

#ALLOW FOR CUSTOM VCF BY LOGGING CHROM AND POS HEADER COL #s FOR SORTING OF VCF LINES
my $chrom_header = $vcf_obj->getColumnNumber("CHROM");
my $pos_header = $vcf_obj->getColumnNumber("POS");
my $prev_chrom = 0;
my $line_count = 0;


#SET UP PROGRESSBAR
my $progressbar;
if ($progress){
    if ($vcf eq "-"){
        print STDERR "Can't use --progress option when input is from STDIN\n";
        $progress = 0;
    }else{
        $progressbar = Term::ProgressBar->new({name => "Biallelic", count => $vcf_obj->countLines("variants"), ETA => "linear", });
    }
}
my $next_update = 0;

#START PROCESSING OUR VARIANTS
LINE: while (my $line = $vcf_obj->readLine){
    $line_count++;
    if ($progress){
        $next_update = $progressbar->update($line_count) if $line_count >= $next_update;
    }
    my %transcript = ();#hash of transcript ids that have a mutation type in @classes - using this hash protects us in case there are multiple alleles causing multiple mentions of the same transcript id in one VAR field
    my $chrom = $vcf_obj->getVariantField("CHROM");
    if ($prev_chrom && $chrom ne $prev_chrom){
    #print biallelic mutations for previous chromosome here...
        my @vcf_lines = ();
        foreach my $gene (keys %allelic_genes){
            my @add_lines  = ();
            #CHECK SEGREGATION IF PEDIGREE
            if ($pedigree){
                @add_lines = check_segregation($ped, \%{$allelic_genes{$gene}});
            }else{
                @add_lines  = check_all_samples_biallelic(\%{$allelic_genes{$gene}});
            }
            if (@add_lines){
                push (@vcf_lines, @add_lines);
                push (@{$listing{$id_to_symbol{$gene}}}, $gene) if $list_genes;
            }
        }
        my $sort = sort_vcf_lines(\@vcf_lines, $chrom_header, $pos_header);
        print $OUT join("\n", @$sort) ."\n" if @$sort;
        %allelic_genes = ();
        %geneline = ();
        %id_to_symbol = ();
    }

    $prev_chrom = $chrom;
    if ($pass_filters){
        next if $vcf_obj->getVariantField("FILTER") ne 'PASS';
    }
    next if not is_autosome($chrom);
    my $have_variant = 0;
    foreach my $sample (@samples){
        $have_variant++ if $vcf_obj->getSampleCall(sample=>$sample, minGQ => $genotype_quality) =~ /[\d+][\/\|][\d+]/;
        last if $have_variant;
    }
    next LINE if not $have_variant;

    if ($identical_genotypes){
        next LINE if not identical_genotypes(\@samples);
    }
    #check for identical genotypes within family if using a ped file
    if ($pedigree){
        foreach my $fam ($ped->getAllFamilies()){
            next LINE if not identical_genotypes($ped->getAffectedsFromFamily($fam));
        }
    }

    my @csq = $vcf_obj->getVepFields(\@csq_fields); #returns array of hashes e.g. $csq[0]->{Gene} = 'ENSG000012345' ; $csq[0]->{Consequence} = 'missense_variant'
    die "No consequence field found for line:\n$line\nPlease annotated your VCF file with ensembl's variant effect precictor before running this program.\n" if not @csq;
CSQ: foreach my $annot (@csq){
        my @anno_csq = split(/\&/, $annot->{consequence});
        #skip NMD transcripts
        if (grep {/NMD_transcript_variant/i} @anno_csq){
            next CSQ;
        }
        my $matches_class = 0;
        next if ($annot->{consequence} eq 'intergenic_variant');
        if($canonical_only){
            next if (not $annot->{canonical});
        }
        if (defined $gmaf){
            if ($annot->{gmaf}){
                if ($annot->{gmaf} =~ /\w+:(\d\.\d+)/){
                    next if $1 >= $gmaf;
                }
            }
        }
        if (defined $any_maf){
            foreach my $some_maf (@available_mafs){
                if ($annot->{$some_maf}){
                    if ($annot->{$some_maf} =~ /\w+:(\d\.\d+)/){
                        next if $1 >= $any_maf;
                    }
                }
            }
        }   

CLASS:  foreach my $class (@classes){
ANNO:        foreach my $ac (@anno_csq){
                if (lc$ac eq lc$class){ 
                    if (lc$class eq 'missense_variant' and %damage_filters){
                        next ANNO if (filter_missense($annot, \%damage_filters, $keep_any_damaging, $filter_unpredicted));
                    }elsif(lc$class eq 'splice_region_variant' and $splice_consensus){
                        my $consensus = $annot->{splice_consensus};
                        next if not $consensus;
                        if ($consensus !~/SPLICE_CONSENSUS\S+/i){
                            print STDERR "WARNING - SPLICE_CONSENSUS annotation $consensus is".
                            " not recognised as an annotation from the SpliceConsensus VEP plugin.\n";
                            next;
                        }
                    }
                    $matches_class++;
                    last CLASS;
                }
            }
        }
        if ($matches_class){
            my %var_hash = create_var_hash($annot, $vcf_obj, [@samples, @reject]);
            foreach my $k (keys %var_hash){
                #$allelic_genes{$subannot[2]}->{$k} =  $var_hash{$k};
                $allelic_genes{$annot->{feature}}->{$k} =  $var_hash{$k};
            }
            # creates a  structure like:
            # $hash{transcript}->{chr:pos/allele}->{sample} = count
            # and $hash{transcript}->{chr:pos/allele}->{mutation} = $annotation
            # and $hash{transcript}->{chr:pos/allele}->{vcf_line} = $line
            # containing info for all relevant @classes
            if ($annot->{symbol}){
                $id_to_symbol{$annot->{feature}} = $annot->{symbol};
            }elsif ($annot->{hgnc}){
                $id_to_symbol{$annot->{feature}} = $annot->{hgnc};
            }elsif($annot->{gene}){
                $id_to_symbol{$annot->{feature}} = $annot->{gene};
            }else{
                $id_to_symbol{$annot->{feature}} = $annot->{feature};
            }
        }
    }
}


my @vcf_lines = ();
foreach my $gene (keys %allelic_genes){
    my @add_lines  = ();
    #CHECK SEGREGATION IF PEDIGREE
    if ($pedigree){
        @add_lines = check_segregation($ped, \%{$allelic_genes{$gene}});
    }else{
        @add_lines  = check_all_samples_biallelic(\%{$allelic_genes{$gene}});
    }
    if (@add_lines){
        push (@vcf_lines, @add_lines);
        push (@{$listing{$id_to_symbol{$gene}}}, $gene) if $list_genes;
    }
}
my $sort = sort_vcf_lines(\@vcf_lines, $chrom_header, $pos_header);
print $OUT join("\n", @$sort) ."\n" if @$sort;

if ($list_genes){
    my $list = sort_gene_listing(\%listing) ;
    print $LIST join("\n", @$list) ."\n";
}

if ($progressbar){
        $progressbar->update($vcf_obj->countLines("variants")) if $vcf_obj->countLines("variants") >= $next_update;
}


###########
sub is_autosome{
    my ($chrom) = @_;
    if ($chrom =~ /^(chr)*(\d+|GL\d+)/i){
        return 1;
    }
    return 0;
}

###########
sub identical_genotypes{
    my (@samp) = @_;
    my %gts = $vcf_obj->getSampleCall(multiple=> \@samp, minGQ => $genotype_quality);
    my %no_calls;
    for (my $i = 0; $i < $#samp; $i++){
        if ($allow_missing and $gts{$samp[$i]} =~ /^\.[\/\|]\.$/){#if we're allowing missing values then skip no calls
            $no_calls{$samp[$i]}++;
            next;
        }elsif ($gts{$samp[$i]} =~ /^\.[\/\|]\.$/){#otherwise a no call means we should go to the next line
            return 0;
        }
        for (my $j = $i + 1; $j <= $#samp; $j++){
            if ($allow_missing and $gts{$samp[$j]} =~ /^\.[\/\|]\.$/){
                $no_calls{$samp[$j]}++;
                next; 
            }elsif ($gts{$samp[$i]} =~ /^\.[\/\|]\.$/){
                return 0;
            }
            return 0 if $gts{$samp[$j]} ne $gts{$samp[$i]};
        }
    }
    #so, if we're here all @samp are identical (or no calls if $allow_missing)
    return 0 if keys %no_calls == @samp;#even if we $allow_missing we don't want to print a variant if none of our @samphave a call
    return 1;
}

###########
sub filter_missense{
#returns 1 if missense should be filtered
#otherwise returns 0;
# uses $keep_any setting to return 0 if any of these predictions match, otherwise all available
# scores must be deleterious/damaging 
# if $filter_missing is used a variant will be filtered if no score is available (overriden by $keep_any setting)
    my ($anno, $filter_hash, $keep_any, $filter_missing) = @_;
#my %default_damaging = (sift => ["deleterious", ],  polyphen => ["probably_damaging", "possibly_damaging",], condel => ["deleterious", ]);
    my %filter_matched = ();
PROG:    foreach my $k (sort keys %$filter_hash){
        my $score = $anno->{lc$k};
        if (not $score or $score =~ /^unknown/i){ #don't filter if score is not available for this variant unless $filter_missing is in effect
            $filter_matched{$k}++ unless $filter_missing;
            next;
        }
SCORE:        foreach my $f (@{$filter_hash->{$k}}){
            if ($f =~ /^\d(\.\d+)*$/){
                my $prob;
                if ($score =~ /^(\d(\.\d+)*)/){
                    $prob = $1;
                }else{
                    next SCORE;#if score not available for this feature ignore and move on 
                }
                if (lc$k eq 'polyphen'){
                    if ($prob >= $f){#higher is more damaging for polyphen - damaging
                        return 0 if $keep_any;
                        $filter_matched{$k}++;
                        next PROG;
                    }else{#benign
                    }
                }else{
                    if ($prob <= $f){#lower is more damaging for sift and condel - damaging
                        return 0 if $keep_any;
                        $filter_matched{$k}++;
                        next PROG;
                    }else{#benign
                    }
                }
            }else{
                $score =~ s/\(.*\)//;
                if (lc$f eq lc$score){#damaging
                    return 0 if $keep_any;
                    $filter_matched{$k}++;
                    next PROG;
                }
            }
        }
        
    }
    foreach my $k (sort keys %$filter_hash){
        #filter if any of sift/condel/polyphen haven't matched our deleterious settings
        return 1 if not exists $filter_matched{$k};
    }
    return 0;
}
###########
sub add_damaging_filters{
    my ($prog, $label, $valid_hash, $default_hash) = @_;
    if ($label){
        if ($label =~ /^\d(\.\d+)*$/){
            die "Numeric values for condel, polyphen or sift filtering must be between 0 and 1.\n" if ( $label < 0 or $label > 1);
            return $label; 
        }else{
            my @lb = split(",", $label);
            foreach my $l (@lb){
                die "Invalid filter parameter '$l' used with --damaging argument.  See --help for valid arguments.\n" if not grep{/^$l$/} @{$valid_hash->{$prog}};
            }
            return @lb; 
        }
        
    }else{#give default values for $prog
        return @{$default_hash->{$prog}}; 
    }
}

###########
sub get_alleles_to_reject{
#requires array ref to sample IDs and hash ref to gene count hash
#returns two hash refs - see %reject_genotypes and %incompatible_alleles below 
    my ($rej, $gene_counts) = @_;
    my @keys = (keys %{$gene_counts});#keys are "chr:pos/allele"
    my %reject_genotypes = ();#collect all genotype combinations present in @$reject samples - these cannot be pathogenic
    my %incompatible_alleles = ();#key is allele, value is an array of alleles each of which can't be pathogenic if key allele is pathogenic and vice versa
    for (my $i = 0; $i < @keys; $i++){
        foreach my $r (@$rej){
            if ($gene_counts->{$keys[$i]}->{$r} >= 1){
                $reject_genotypes{"$keys[$i]/$keys[$i]"}++ if $gene_counts->{$keys[$i]}->{$r} >= 2;#homozygous therefore biallelic
                for (my $j = $i + 1; $j < @keys; $j++){#check other alleles to see if there are any compund het combinations
                    if ($gene_counts->{$keys[$j]}->{$r} >= 1){
                        $reject_genotypes{"$keys[$i]/$keys[$j]"}++;
                        push @{$incompatible_alleles{$keys[$i]}}, $keys[$j];
                        push @{$incompatible_alleles{$keys[$j]}}, $keys[$i];
                    }
                }
            }
        }
    }
    return (\%reject_genotypes, \%incompatible_alleles);
}


###########
sub get_biallelic{
#arguments are array ref to samples, hash ref to reject genotypes, hash ref to incompatible genotypes and gene_counts hash ref
#returns hash of samples to arrays of potential biallelic genotypes
    my ($aff, $reject_geno, $incompatible, $gene_counts) = @_;
    my @keys = (keys %{$gene_counts});#keys are "chr:pos/allele"
    my %possible_biallelic_genotypes = ();#keys are samples, values are arrays of possible biallelic genotypes
    my %biallelic = ();#same as above, for returning final list of valid biallelic combinations
    for (my $i = 0; $i < @keys; $i++){
        next if $reject_geno->{"$keys[$i]/$keys[$i]"};#allele $i can't be pathogenic if homozygous in a @reject sample
        foreach my $s (@$aff){
            if ($gene_counts->{$keys[$i]}->{$s} >= 1){
                push @{$possible_biallelic_genotypes{$s}}, "$keys[$i]/$keys[$i]" if $gene_counts->{$keys[$i]}->{$s} >= 2;#homozygous therefore biallelic
                if (not $homozygous_only){#don't consider hets if --homozygous_only flag is in effect
                    for (my $j = $i + 1; $j < @keys; $j++){#check other alleles to see if there are any compund het combinations
                        if ($gene_counts->{$keys[$j]}->{$s} >= 1){
                            push @{$possible_biallelic_genotypes{$s}}, "$keys[$i]/$keys[$j]" if not $reject_geno->{"$keys[$i]/$keys[$j]"};
                        }
                    }
                }
            }
        }
    }
    #so now our $aff only have genotypes not present in %{$reject_geno}
    #however, between all our samples we could be using pairs of alleles from %{$incompatible}
    # i.e. if two alleles are present in an unaffected (@reject) sample at most one allele can be pathogenic
    # so we can't use both in different affected (@$aff) samples
    
    foreach my $gt (@{$possible_biallelic_genotypes{$samples[0]}}){
        if (@samples > 1){
            my @incompatible = ();# keep the alleles incompatible with current $gt here
            my %compatible_genotypes = (); #samples are keys, values are genotypes that pass our test against incompatible alleles
            foreach my $allele (split("\/", $gt)){
                push (@incompatible, @{$incompatible->{$allele}}) if exists $incompatible->{$allele};
            }
            foreach my $s (@$aff[1..$#{$aff}]){
                foreach my $s_gt (@{$possible_biallelic_genotypes{$s}}){
                    if ($identical_genotypes){
                        next if $s_gt ne $gt;
                    }
                    my @s_alleles =  (split("\/", $s_gt));
                    if (not grep { /^($s_alleles[0]|$s_alleles[1])$/ } @incompatible){
                        push @{$compatible_genotypes{$s}}, $s_gt;
                    }
                }
            }
            if (check_keys_are_true([@$aff[1..$#{$aff}]], \%compatible_genotypes)){
                push @{$biallelic{$samples[0]}}, $gt;    
                foreach my $s (@samples[1..$#samples]){
                    foreach my $sgt (@{$compatible_genotypes{$s}}){
                        push @{$biallelic{$s}}, $sgt;    
                    }
                }
            }
        }else{
            foreach my $gt (@{$possible_biallelic_genotypes{$samples[0]}}){
                push @{$biallelic{$samples[0]}}, $gt;    
            }
        }
    }
    foreach my $k (keys %biallelic){
        #remove duplicate genotypes for each sample
        my %seen = ();
        @{$biallelic{$k}} = grep {!$seen{$_}++}  @{$biallelic{$k}};
    }
    return %biallelic;
}


###########
sub check_segregation{
#checks whether variants segregate appropriately per family
#can check between multiple families using check_all_samples_biallelic
#returns hash from $gene_counts with only correctly segregating alleles
    my ($p, $gene_counts) = @_;
    my @keys = (keys %{$gene_counts});#keys are "chr:pos/allele"
    my %seg_count = ();#return version of %{$gene_counts} containing only alleles that appear to segregate correctly
    
    #Iterate over all @reject to store %reject_genotypes and %incompatible_alleles
    my ($reject_genotypes, $incompatible_alleles) = get_alleles_to_reject(\@reject, $gene_counts);
    #Iterate overl all @samples to store possible biallelic genotypes
    my %biallelic_candidates = get_biallelic(\@samples, $reject_genotypes, $incompatible_alleles, $gene_counts);
    #Then for each family identify common biallelic genotypes but throw away anything if neither allele present in an obligate carrier

    foreach my $f ($ped->getAllFamilies){
        my %affected_ped = map {$_ => undef} $ped->getAffectedsFromFamily($f);
        my @affected = grep { exists $affected_ped{$_} } @samples;
        my %unaffected_ped = map {$_ => undef} $ped->getUnaffectedsFromFamily($f);
        my @unaffected = grep { exists $unaffected_ped{$_} } @reject;
        #get intersection of all @affected biallelic genotypes (we're assuming there's no phenocopy so we're looking for identical genotypes)
        my %intersect = map {$_ => undef}  @{$biallelic_candidates{$affected[0]}};
        foreach my $s (@affected[1..$#affected]){
            my @biallelic = grep {exists ($intersect{$_}) } @{$biallelic_candidates{$s}};
            %intersect = map {$_ => undef}  @biallelic;
        }
        #we've already checked that these allele combinations are not present in unaffected members including parents.
        #check that parents don't contain 0 of a compound het (admittedly this does not allow for hemizygous variants in case of a deletion in one allele)
        foreach my $key (keys %intersect){
            foreach my $u (@unaffected){
                if ($ped->isObligateCarrierRecessive($u)){
                    my @al = split(/\//, $key);  
                    if ($gene_counts->{$al[0]}->{$u} == 0 and $gene_counts->{$al[1]}->{$u} == 0){#0 means called as not having allele, -1 means no call
                        delete $intersect{$key};
                    }
                }
            }
        }
        #now %intersect only has viable genotypes for this family
        #Put these genotypes into %seg_counts
        foreach my $k (keys %intersect){
            my @al = split(/\//, $k);  
            #add viable alleles to %seg_count
            $seg_count{$al[0]} = $gene_counts->{$al[0]};
            $seg_count{$al[1]} = $gene_counts->{$al[1]};
        }
    }
    #Find any common variation by running check_all_samples_biallelic using \%seg_counts
    return check_all_samples_biallelic(\%seg_count);
}

###########
sub check_all_samples_biallelic{
    my ($gene_counts) = @_;
    
    #we need to go through every possible combination of biallelic alleles 
    #(represented as chr:pos/allele) to compare between @samples and against @$reject
    my %vcf_lines;
    my @keys = (keys %{$gene_counts});#keys are "chr:pos/allele"
    my %possible_biallelic_genotypes = ();#keys are samples, values are arrays of possible biallelic genotypes
    #first check @$reject alleles and collect non-pathogenic genotpes in %reject_genotypes - the assumption here is that
    # the disease alleles are rare so not likely to be in cis in a @reject sample while in trans in an affected sample therefore we can reject
    # assuming presence of two alleles in a reject sample means either they are in cis or are harmless when in trans
    #also note alleles that can't BOTH be pathogenic storing them in %incompatible alleles
    my ($reject_genotypes, $incompatible_alleles) = get_alleles_to_reject(\@reject, $gene_counts);
    my %biallelic_candidates = get_biallelic(\@samples, $reject_genotypes, $incompatible_alleles, $gene_counts);
    #%biallelic_candidates - keys are samples, values are arrays of biallelic genotypes
    foreach my $s (keys %biallelic_candidates){
        foreach my $gt (@{$biallelic_candidates{$s}}){
            foreach my $allele ( split(/\//, $gt)){
                $vcf_lines{$gene_counts->{$allele}->{vcf_line}}++;
            }
        }
    }
    return keys %vcf_lines;
}
###########
sub check_keys_are_true{
    my ($key_array, $hash) = @_;
    foreach my $k (@$key_array){
        return 0 if not $hash->{$k};
    }
    return 1;
}

###########
sub create_var_hash{
    my ($annotation, $vcf_obj, $samp) = @_;
    my %var_hash;
    my $coord = $vcf_obj->getVariantField("CHROM") . ":" . $vcf_obj->getVariantField("POS");
    #we should check sample alleles against subannot alleles
    my @alts = $vcf_obj->readAlleles(alt_alleles => 1);
    my $ref = $vcf_obj->getVariantField("REF");
    #(Allele Gene Feature Feature_type Consequence HGNC);
    my $i = 0; #count alleles as 1-based list to correspond to GT field in VCF
    foreach my $alt (@alts){
        $i++;
        my $vep_allele = $vcf_obj->altsToVepAllele(alt => $alt);
        if (uc($vep_allele) eq uc($annotation->{allele})){
            $var_hash{"$coord-$i"}->{mutation} = $annotation;
            $var_hash{"$coord-$i"}->{vcf_line} = $vcf_obj->get_currentLine;
        }else{
            next;
        }
        foreach my $s (@$samp){
            my $gt = $vcf_obj->getSampleCall(sample=>$s, minGQ => $genotype_quality);
            if ($gt =~ /$i[\/\|]$i/){
                $var_hash{"$coord-$i"}->{$s} = 2;#homozygous for this alt allele
            }elsif ($gt =~ /\d[\/\|]$i/ or $gt =~ /$i[\/\|]\d/ ){
                $var_hash{"$coord-$i"}->{$s} = 1;#het for alt allele
            }elsif ($gt =~ /\d[\/\|]\d/){
                $var_hash{"$coord-$i"}->{$s} = 0;#does not carry alt allele
            }else{
                $var_hash{"$coord-$i"}->{$s} = -1;#no call
            }
        }
    }
    return %var_hash;
}
###########
sub sort_gene_listing{
    my ($gene_list) = @_;
    #$gene_list is a ref to hash with keys =  GeneSymbol and values = array of transcript IDs
    my @sorted_list = ();
    foreach my $k (sort keys %$gene_list){
        push @sorted_list, join(":", $k, sort @{$gene_list->{$k}});
    }
    return \@sorted_list;
}
###########
sub sort_vcf_lines{
    my ($v_lines, $chrom_col, $pos_col) = @_;
    #remove duplicates
    my %seen = ();
    @$v_lines = grep { !$seen{$_}++ } @$v_lines;
    #sort in coordinate order
    my $sort_obj = SortGenomicCoordinates->new(array => $v_lines, type => "custom", col => $chrom_col + 1, start_col => $pos_col - $chrom_col, stop_col => $pos_col -  $chrom_col);
    $sort_obj->order();
    return $sort_obj->get_ordered;
}
###########
#=item B<--allow_missing>
#When multiple --samples are being analysed use this flag to stop the script rejecting variants that are missing (as in no genotype call) from other samples.

=head1 NAME

findBiallelicVep.pl - identify variants that make up potential biallelic variation of a gene

=head1 SYNOPSIS

    findBiallelicVep.pl -i <variants.vcf> -s <sample1> <sample2> [options]
    findBiallelicVep.pl --help (show help message)
    findBiallelicVep.pl --manual (show manual page)

=cut 

=head1 ARGUMENTS

=over 8 

=item B<-i    --input>

VCF file annotated with Ensembl's variant_effect_predictor.pl script.

=item B<-o    --output>

File to print output (optional). Will print to STDOUT by default.

=item B<-l    --list>

File to print a list of genes containing biallelic variants to. If you use this argument without specifying a value the list will be printed to STDERR;

=item B<-s    --samples>

One or more samples to identify biallelic genes from.  When more than one sample is given only genes with biallelic variants in ALL samples will be returned.

=item B<-r    --reject>

ID of samples to exclude variants from. Biallelic variants identified in these samples will be used to filter those found in samples supplied via the --samples argument.

=item B<-x    --reject_all_except>

Reject variants present in all samples except these. If used without an argument all samples in VCF that are not specified by --samples argument will be used to reject variants. If one or more samples are given as argument to this option then all samples in VCF that are not specified by --samples argument or this argument will be used to reject variants.

=item B<-f    --family>

A PED file (format described below) containing information about samples in the VCF. In this way you can specify one or more families to allow the program to analyze biallelic variation that segregates correctly among affected and unaffected members. This assumes that any given family will have the same monogenic cause of recessive disease (i.e. this will not find phenocopies segregating in a family). One advantage of using a PED file is that the program can identify obligate carriers of a recessive disease and filter variants appropriately.  Can be used instead of or in conjunction with --samples (-s), --reject (-r) and --reject_all_except (-x) arguments. 

Not all samples in a given PED file need be present in the VCF. For example, you may specify an affected child not present in a VCF to indicate that an unaffected sample that IS present in the VCF is an obligate carrier. 

PED format - from the PLINK documentation:

       The PED file is a white-space (space or tab) delimited file: the first six columns are mandatory:

            Family ID
            Individual ID
            Paternal ID
            Maternal ID
            Sex (1=male; 2=female; other=unknown)
            Phenotype

       Affection status, by default, should be coded:

           -9 missing
            0 missing
            1 unaffected
            2 affected

This script will ignore any lines in a PED file starting with '#' to allow users to include comments or headers.

=item B<--classes>

One or more mutation classes to retrieve. By default only variants labelled with one of the following classes will count towards biallelic variants:

        transcript_ablation
        splice_donor_variant
        splice_acceptor_variant
        stop_gained
        frameshift_variant
        stop_lost
        initiator_codon_variant
        inframe_insertion
        inframe_deletion
        missense_variant
        transcript_amplification
        TFBS_ablation
        TFBS_amplification
        regulatory_region_ablation
        regulatory_region_amplification

The user can specify one or more of the following classes instead: 

        transcript_ablation
        splice_donor_variant
        splice_acceptor_variant
        stop_gained
        frameshift_variant
        stop_lost
        initiator_codon_variant
        inframe_insertion
        inframe_deletion
        missense_variant
        transcript_amplification
        splice_region_variant
        incomplete_terminal_codon_variant
        synonymous_variant
        stop_retained_variant
        coding_sequence_variant
        mature_miRNA_variant
        5_prime_UTR_variant
        3_prime_UTR_variant
        intron_variant
        NMD_transcript_variant
        non_coding_exon_variant
        nc_transcript_variant
        upstream_gene_variant
        downstream_gene_variant
        TFBS_ablation
        TFBS_amplification
        TF_binding_site_variant
        regulatory_region_variant
        regulatory_region_ablation
        regulatory_region_amplification
        feature_elongation
        feature_truncation
        intergenic_variant


=item B<-a    --add_classes>

Specify one or more classes, separated by spaces, to add to the default mutation classes used for finding biallelic variants.

=item B<--consensus_splice_site>

Use this flag in order to keep splice_region_variant classes only if they are in a splice consensus region as defined by the SpliceConsensus plugin. You do not need to specify 'splice_region_variant' using --classes or --add_classes options when using this flag. You B<MUST> have used the SpliceConsensus plugin when running the VEP for this option to work correctly.

=item B<--canonical_only>

Only consider canonical transcripts.

=item B<-d    --damaging>

Specify SIFT, PolyPhen or Condel labels or scores to filter on. Add the names of the programs you want to use, separated by spaces, after the --damaging option. By default SIFT will keep variants labelled as 'deleterious', Polyphen will keep variants labelled as 'possibly_damaging' or 'probably_damaging' and  Condel will keep variants labelled as 'deleterious'.

If you want to filter on custom values specify values after each program name in the like so: 'polyphen=probably_damaging'. Seperate multiple values with commas - e.g. 'polyphen=probably_damaging,possibly_damaging,unknown'. You may specify scores between 0 and 1 to filter on scores rather than labels - e.g. 'sift=0.3'. For polyphen, variants with scores lower than this score are considered benign and filtered, for SIFT and Condel higher scores are considered benign.

Valid labels for SIFT: deleterious, tolerated

Valid labels for Polyphen: probably_damaging, possibly_damaging, benign, unknown

Valid labels for Condel : deleterious, neutral


To use default values for all three programs use 'all' (i.e. '--damaging all').

The default behaviour is to only keep variants predicted as damaging by ALL programs specified, although if the value is not available for one or more programs than that program will be ignored for filtering purposes.


=item B<-k    --keep_any_damaging>

If using multiple programs for filters for --damaging argument use this flag to keep variants predicted to be damaging according to ANY of these programs.

=item B<-u    --unpredicted_missense>

Skip variants that do not have a score from one or more programs specified by the --damaging argument. The --keep_any_damaging argument will override this behaviour if any of the available predictions are considered damaging.

=item B<-g    --gmaf>

Use a value between 0.00 and 0.50 to specify global minor allele frequencey filtering. If GMAF is available for variant it will be filtered if equal to or greater than the value specfied here.

=item B<--maf>

Like gmaf but filter on any population specific minor allele frequency annotated by the VEP as well as the GMAF.

=item B<-q    --quality>

Minimum genotype qualities to consider. This applies to samples specified by both --sample and --reject. Anything below this threshold will be considered a no call. Default is 20.

=item B<-e    --equal_genotypes>

Use this flag if you only want to consider genotypes that are identical in each sample to count towards biallelic variation. Potentially useful if looking at several related individuals segregating the same disease and not using a PED file to specify their relationships.

=item B<--check_all_samples>

Check all samples in VCF. Assumes all samples are affected.

=item B<--pass_filters>

Only consider variants with a PASS filter field.

=item B<--progress>

Show a progress bar while working.

=item B<--homozygous_only>

Only consider homozygous variants, ignore potential compound heterozygotes (i.e. if autozygosity is assumed). 

=item B<---help>

Show the program's help message.

=item B<--manual>

Show the program's manual page.

=back

=cut

=head1 EXAMPLES

    findBiallelicVep.pl -i <variants.vcf> -s <sample1> <sample2> -r <sample3> <sample4>  -o output.vcf -l genelist.txt
    #find genes with biallelic variants in two unrelated samples but not in two unaffected samples. 

    findBiallelicVep.pl -i <variants.vcf> -s <sample1> <sample2> -r <sample3> <sample4> -d polyphen --maf 0.01 -o output.vcf -l genelist.txt
    #as above but only consider missense variants predicted damaging by polyphen and with a minor allele frequency less than 1%. 

    findBiallelicVep.pl -i <variants.vcf> -s <sample1> <sample2> -e -o output.vcf -l genelist.txt
    #find genes with biallelic variants in two related samples where you expect them to share the same causative variant.

    findBiallelicVep.pl -i <variants.vcf> -f families.ped -o output.vcf -l genelist.txt -q 30
    #use families.ped file to describe affected and unaffected individuals, only consider calls with genotype quality of 30 or higher

=cut

=head1 DESCRIPTION

This program reads VCF files annotated with Ensembl's Variant Effect Predictor and identifies transcripts with potential biallelic variation matching the various options specified above for the purpose of identifying potential recessively inherited pathogenic variants.  When more than one sample is specified using the --samples (-s) argument transcripts are identified that contain (not necessarily identical) potential biallelic variation in all samples. If multiple samples are specified in a PED file passed to the script with the --family (-f) argument, the program will attempt to find identical biallelic combinations within families and transcripts that contain potential biallelic variation in all affected samples from different families.

Genes are considered to contain potential biallelic variation if they either contain homozygous variants or two or more heterozygous variants. Phase can not be determined for variants so variants in cis may be erroneously considered to be potential biallelic variation.  Using variant data from unaffected parents with the --reject (-r) option or by specifying a PED file with the --family (-f) option  can help get around this issue.  Any samples specified using the --reject option will be used to remove biallelic variant combinations present - specifically, genotype combinations identified in affected samples (--samples) but also present in samples specified using the --reject argument will be removed from output. In this manner, if you have data from unaffected parents you should be able to avoid the problem of false positives from variants in cis as well as removing any shared genuine biallelic but non-pathogenic variation. However, this program does not require parental samples and can attempt to infer phase from a single parent if only one is available if the relationship is specified in a PED file passed to the script with the --family (-f) argument.

While related samples will be most useful in filtering using the --reject argument, data from any unaffected sample can be used to remove apparently non-pathogenic biallelic variation. Furthermore, while unrelated affected individuals can be used to identify shared genes containing apparent biallelic variation (when you believe the disorder to be caused by variation in the same gene), if using several related affected individuals you may use the --equal_genotypes flag to tell the program to only look for variants that are shared among all affected individuals AND potentially biallelic.

Note that this program only considers autosomal recessive disease, it ignores X, Y and mitochondrial chromosomes.



=cut

=head1 AUTHOR

David A. Parry

University of Leeds

=head1 COPYRIGHT AND LICENSE

Copyright 2012, 2013  David A. Parry

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with this program. If not, see <http://www.gnu.org/licenses/>.

=cut


