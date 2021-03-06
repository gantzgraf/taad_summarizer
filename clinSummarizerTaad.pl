#!/usr/bin/env perl 
#David A. Parry, June 2015

use strict;
use warnings;
use DBI;
use Getopt::Long;
use Data::Dumper;
use Term::ProgressBar;
use POSIX qw/strftime/;
use Excel::Writer::XLSX;
use Excel::Writer::XLSX::Utility;
use List::Util qw(first sum max);
use Pod::Usage;
use File::Basename;
use FindBin;
use IO::Uncompress::Gunzip qw(gunzip $GunzipError);
use HTTP::Tiny;
use JSON;
use lib "$FindBin::Bin/lib/vcfhacks/lib";
use VcfReader;
use TextToExcel;

my $progressbar;
my @allele_balance = ();
my %seq_cache = ();
my %opts = (b => \@allele_balance);
GetOptions(
    \%opts,
    '1|single_sheet',
    'a|allele_cutoff=f', #remove if allele is present in this proportion or more calls
    'b|allele_balance=f{,}', #min and optional max alt allele ratio per sample call
    'd|depth=i',         #optional min depth for sample call
    'f|filter_output=s', #optional output file for calls filtered on allele_cutoff
    'g|gq=f',            #min GQ quality for calls
    'h|?|help',
    'i|input=s',        #vcf input
    'keep_unvalidated', #still retain variants even if validation status is '2' (did not validate'
    'manual',
    'n|no_blanks',      #no blank samples
    'o|output=s',       #xlsx output
    'phenotype_file=s',   #read a csv file of patient IDs and phenotype information
    'pl=f',              #PL score cutoff for REF genotype
    'primer_file=s',      #read a tab delimited file of primers and coordinates to assign primer IDs to variants
    'p|progress',       #show a progress bar?
    'rules=s',        #optional tsv file of mutation rules
    'r|rest_server=s',   #URL of REST server to use if not the default (http://grch37.rest.ensembl.org)
    's|scan_gxy',       #scan for GXY sequences throughout sequence rather than relying on VEP annotation
    't|transcript_database=s',  #optional sqlite database of transcripts and protein info 
    'validations_file=s', #csv file of validation status of variants
    'verbose',        #print extra progress information
    'x|do_not_merge',    #do not merge cells
    'y|frequency=f',     #filter on this allele frequency if dbSNP/EVS/ExAC annot. found
    'z|reports_folder=s', #create per sample reports and put them in this folder
) or pod2usage(-exitval => 2, -message => "Syntax error.\n"); 

pod2usage( -verbose => 1 ) if $opts{h};
pod2usage( -verbose => 2 ) if $opts{manual};
pod2usage( -exitval => 2, -message => "-i/--input is required" ) if (not $opts{i});
#pod2usage( -exitval => 2, -message => "-m/--hgmd is required" ) if (not $opts{m});
if ($opts{rules} and not $opts{t}){
    my $msg = <<EOT
WARNING: CDD or Uniprot rules will not be used without specifying a transcript database using the -t/--transcript_database option. Only 'coordinate' based rules will be considered.
EOT
;
    informUser($msg);
}

#create our http client for ensembl REST queries 
my $http = HTTP::Tiny->new();
my $server = $opts{rest_server} ? $opts{rest_server} : 'http://grch37.rest.ensembl.org';
my $min_gq = defined $opts{g} ? 0 : $opts{g}; #default min GQ of 0
my $af = defined $opts{y} ? 0.001 : $opts{y}; #default of 0.1 % cutoff in external databases

#open VCF, get samples and get VEP annotations
informUser("Checking input VCF\n");
my @vhead              = VcfReader::getHeader($opts{i});
die "VCF header not OK for $opts{i}\n" if not VcfReader::checkHeader(header => \@vhead);
my %samples_to_columns = VcfReader::getSamples(header => \@vhead, get_columns => 1);
my %vep_fields         = VcfReader::readVepHeader(header => \@vhead);
my %info_fields = VcfReader::getInfoFields(header => \@vhead);
my %af_info_fields     = getAfAnnotations(\@vhead);
my $total_var;

#check primer_file if supplied
my @primers = (); #create an array of hash refs with id, chr, start, end, f and r keys
if ($opts{primer_file}){
    informUser("Checking primer file\n");
    @primers = readPrimerFile();
}

#check validations_file if supplied
my %validated = (); #key is variant unique ID, value is 1 for validated, 2 for did not validate, 0 for not done
if ($opts{validations_file}){
    informUser("Checking validations file\n");
    %validated = readValidationsFile();
}
#check phenotype_file if supplied
my $phenotypes ; # hash ref key is sample ID, value is anon hash of phenotype fields to values
my @pheno_fields = (); #list of phenotype fields found
if ($opts{phenotype_file}){
    informUser("Checking phenotype file\n");
    ($phenotypes, @pheno_fields) = readPhenotypeFile();
}
#set consequence ranks;
my %so_ranks = ();
setConsequenceRanks();

#open and check transcript and crossref database list
my $dbh;
my $driver   = "SQLite";
my %search_handles = ();
my %transcript_ranks = ();
my %enst_xref = ();
readTranscriptDatabase();

#check rules
my %rules = ();
setMutationRules();

#setup our hash of headers

my %headers = getHeaders();

#setup output
#Excel related global variables
my %sheets = ();
my $header_formatting;    
my $std_formatting;     
my $url_format;
my $xl_obj;
#filehandle for --allele_cutoff filtered variants
informUser("Preparing output file\n");
my $FILTER_OUT;
setupOutput();

#set up counts for variant indexes of each sheet
my %variant_counts = map { $_ => 0 } qw / HGMD LOF DamagingMissense BenignMissense Other / ;

#store variants per sample in this hash for writing sample sheet
my %sample_vars = (); 

#set up progress bar if user wants one
my $next_update = 0;
my $n = 0;
if ($opts{p}){
    informUser("Calculating file length for progress bar...\n");
    $total_var = VcfReader::countVariants( $opts{i} );
    informUser("$opts{i} has $total_var variants.\n");
    $progressbar = Term::ProgressBar->new(
        { name => "Analyzing", 
          count => ($total_var), 
          ETA => "linear" 
        } 
    );
    $progressbar->rbrack('>');
}

#get filehandle and start reading variants
my $FH = VcfReader::_openFileHandle($opts{i}); 
informUser("Commencing variant analysis\n");
while (my $l = <$FH>){
    next if $l =~ /^#/;
    assessAndWriteVariant($l);
    $n++;
    if ($progressbar){
        $next_update = $progressbar->update($n) if $n >= $next_update;
    }
}
close $FH;
if ($progressbar){
    $progressbar->update($total_var) if $total_var >= $next_update;
}
if ($FILTER_OUT){
    close $FILTER_OUT;
}
$progressbar = undef;
informUser("Done writing variant sheets - writing sample summary...\n"); 
writeSampleSummary();
informUser("Done.\n");
if ($xl_obj){
    $xl_obj->DESTROY();
}

###########################################################
sub readTranscriptDatabase{
    return if not $opts{t};
    $dbh = DBI->connect("DBI:$driver:$opts{t}", {RaiseError => 1})
      or die "Could not connect to sqlite database '$opts{t}': " . DBI->errstr . "\n";
    my %tables = map {$_ => undef} $dbh->tables;
    foreach my $t ( qw / transcripts uniprot cdd HGMD_VEP ClinVar_VEP/ ){
        if (not exists $tables{"\"main\".\"$t\""}){
            die "ERROR: Could not find table '$t' in $opts{t} - did you use dbCreator.pl to create this database?\n";
        }
    }
    my $q = "SELECT EnsemblGeneID, EnsemblTranscriptID, EnsemblProteinID, RefSeq_mRNA, RefSeq_peptide, CCDS,  Uniprot, TranscriptRank FROM transcripts";
    #we could do lazy loading for when we need to rank transcripts
    #but for current uses this isn't really worth the effort
    my $all = $dbh->selectall_arrayref($q);
    foreach my $tr (@$all){
        $transcript_ranks{$tr->[0]}->{$tr->[1]} = $tr->[7];
        my $i = 3;
        my %xrefs = map {$_ => $i++} qw / refseq_mrna refseq_peptide ccds uniprot / ; 
        foreach my $x (keys %xrefs){
            if (defined $tr->[$xrefs{$x}]){
                $enst_xref{$tr->[1]}->{$x} = $tr->[$xrefs{$x}];
            }
        }
    }
    %search_handles = 
    (
        cdd     =>  $dbh->prepare 
        (
            qq{ select * FROM cdd 
                WHERE UniprotId == ? 
                and End >= ? 
                and Start <= ? 
            } 
        ),

        uniprot =>  $dbh->prepare 
        (
            qq{ select * FROM uniprot 
                WHERE UniprotId == ? 
                and End >= ? 
                and Start <= ? 
            } 
        ),
        
        hgmd_pos => $dbh->prepare
        (
            qq{ select hgmd_id, disease, variant_class, gene_symbol, hgvs 
                FROM HGMD
                WHERE chrom == ? 
                and pos == ? 
                and ref == ?
                and alt == ?
            }
        ),

        hgmd_aa =>  $dbh->prepare
        (
            qq{ select hgmd_id, feature, consequence, protein_position, amino_acids, hgvsc, hgvsp
                 FROM HGMD_VEP
                WHERE feature == ? 
                and protein_position == ? 
            }
        ),
        
        hgmd_id =>  $dbh->prepare
        (
            qq{ select variant_class, disease FROM HGMD
                WHERE hgmd_id == ? 
            }
        ),

        hgmd_hgvs =>  $dbh->prepare
        (
            qq{ select hgvsc, hgvsp
                 FROM HGMD_VEP
                WHERE hgmd_id == ? 
            }
        ),

        clinvar_pos =>  $dbh->prepare
        (
            qq{ select measureset_id, pathogenic, 
                clinical_significance, all_traits, conflicted 
                FROM ClinVar
                WHERE chrom == ? 
                and pos == ? 
                and ref == ?
                and alt == ?
            }
        ),

        clinvar_aa =>  $dbh->prepare
        (
            qq{ select measureset_id, feature, consequence, protein_position, amino_acids, hgvsc, hgvsp
                FROM ClinVar_VEP
                WHERE feature == ? 
                and protein_position == ? 
            }
        ),


        clinvar_hgvs =>  $dbh->prepare
        (
            qq{ select hgvsc, hgvsp
                FROM ClinVar_VEP
                WHERE measureset_id == ? 
            }
        ),

        clinvar_id =>  $dbh->prepare
        (
            qq{ select pathogenic, clinical_significance, conflicted, all_traits 
                FROM ClinVar
                WHERE measureset_id == ? 
            }
        ),


    );

    if (exists $tables{"\"main\".\"EvolutionaryTrace\""}){
        $search_handles{et} = $dbh->prepare
        (
            qq{ select score FROM EvolutionaryTrace
                WHERE EnsemblTranscriptID == ? 
                and Position == ? 
                and WildTypeResidue == ? 
                and MutantResidue == ? 
            }
        );
    }

}

###########################################################
sub getAfAnnotations{
    my $h = shift;
    return if not $af;
    my %af_found = ();
    my @af_fields =  qw ( 
        AS_CAF
        AS_G5A
        AS_G5
        AS_COMMON
        EVS_EA_AF
        EVS_AA_AF
        EVS_ALL_AF
    );
    foreach my $key (keys %info_fields){
        my $warning = <<EOT
[WARNING] Found expected frequency annotation ($key) in INFO fields, but 'Number' field is $info_fields{$key}->{Number}, expected 'A'. Ignoring this field.
EOT
;
        my $info = <<EOT
[INFO] Found allele frequency annotation: $key. This will be used for filtering on allele frequency.
EOT
;
        if (grep { $key eq $_ } @af_fields){
            if ($info_fields{$key}->{Number} ne 'A'){
                print STDERR $warning;
            }else{
                print STDERR $info;
                $af_found{$key} = $info_fields{$key};
            }
        }else{
            if ($key =~ /^FVOV_AF_\S+$/){
                if ($info_fields{$key}->{Number} ne 'A'){
                    print STDERR $warning;
                }else{
                    print STDERR $info;
                    $af_found{$key} = $info_fields{$key};
                }
            }
        }
    }
    return %af_found;
}
 
###########################################################
sub writeSampleSummary{
    my $sample_sheet = $xl_obj->get_worksheets()->[$sheets{SampleSummary}];
    my $row = 1;
    my %most_damaging = ();#keys are categories, values are array of sample variant array refs
    foreach my $s (
            sort {$samples_to_columns{$a} <=> $samples_to_columns{$b}} 
            keys %samples_to_columns
    ){
        #write out numbers of each variant class per sample
        my $col = 0;
        foreach my $field ( @{$headers{sample}} ){
            if ($field eq 'Sample'){
                $sample_sheet->write($row, $col, $s)
            }elsif (exists $sample_vars{$s}->{$field} ){
                $sample_sheet->write($row, $col, scalar @{$sample_vars{$s}->{$field}});
                #$sample_sheet->write_comment($row, $col,  join("\n", @{$sample_vars{$s}->{$field}}), visible => 0);
            }else{
                $sample_sheet->write($row, $col, 0);
            }
            $col++;
        }
        $row++;

        #determine most damaging consequence category for this sample
        # and store in most damaging to allow output in order of most 
        # likely pathogenic 
        my @csq = sort byCsqClass keys %{$sample_vars{$s}}; 
        if (not @csq){ #no variants for this sample
            my @no_var = (0, 0, $s); 
            #output a line with empty GT fields etc. 
            push @no_var, map {"-"} 1..6;
            #but including phenotype info if present
            if (%validated){
                push @no_var , "-";
            }
            if ($opts{phenotype_file}){
                #search phenotypes
                foreach my $ph (@pheno_fields){
                    if (exists $phenotypes->{$s}){
                        push @no_var, $phenotypes->{$s}->{$ph};
                    }else{
                        push @no_var, '-';
                    }
                }
            }
            push @{ $most_damaging{NONE} }, \@no_var;
        }else{
            if (@{$sample_vars{$s}->{$csq[0]}} > 1){ 
            #if multiple variants with most damaging category choose 
            #the highest path score followed by highest CADD score
            #path score and CADD score will be first and second entry in array ref
                @{$sample_vars{$s}->{$csq[0]}} = 
                    sort {
                        $b->[0] <=> $a->[0] ||
                        $b->[1] <=> $a->[1]
                    } @{$sample_vars{$s}->{$csq[0]}};
            }
            push @{ $most_damaging{$csq[0]} }, $sample_vars{$s}->{$csq[0]}->[0]; 

        }
    }
    foreach my $k (sort byCsqClass keys %most_damaging){
        #order each category by path score, then by CADD score
        #path score and CADD score will be first and second entry in array ref
        foreach my $var ( 
            sort { $b->[0] <=> $a->[0] || 
                   $b->[1] <=> $a->[1] 
            } @{ $most_damaging{$k} } 
        ){
            #remove path score and cadd score from beginning of line
            shift @$var; 
            shift @$var; 
            $xl_obj->writeLine
            (
                line => $var,
                worksheet  => $sheets{MostDamaging},
            );
        }        
    }
}

###########################################################
sub byCsqClass{
    if ($a eq $b){
        return 0;
    }
    foreach my $class ("Pathogenic", "Likely Pathogenic", "Uncertain Significance", "NONE"){
        if ($a eq "$class"){
            return -1;
        }elsif ($b eq "$class"){
            return 1;
        }
    }
    return 0;
}
        


###########################################################
sub readPhenotypeFile{
    my %pheno = (); #key is variant unique ID, value is anon hash of phenotype info
    open (my $PHENO, $opts{phenotype_file}) 
      or die "Can't open phenotype file $opts{phenotype_file}: $!\n";
    chomp (my $header= <$PHENO>);
    $header =~ s/^#+//;
    my $delimiter = '';
    my %cols = ();
    foreach my $d (",", "\t",){
        $delimiter = $d;
        %cols = getColumns($header, 1, $d);
        last if exists $cols{sample_id};
    }
    if (not exists $cols{sample_id}){
        die "Could not find required column 'sample_id' in phenotype file!\n";
    }
    while ( my $line = <$PHENO> ){
        chomp $line;
        my @split = split($delimiter, $line); 
        foreach my $f (sort keys %cols){
            next if $f eq 'sample_id';
            $pheno{$split[ $cols{sample_id} ] } ->{$f} = $split[ $cols{$f} ] ;
        }
    }
    close $PHENO;
    delete $cols{sample_id}; 
    return \%pheno, sort keys %cols;
}

###########################################################
sub readValidationsFile{
    my %val = (); #key is variant unique ID, value is 1 for validated, 2 for did not validate, 0 for not done
    open (my $VAL, $opts{validations_file}) 
      or die "Can't open validations file $opts{validations_file}: $!\n";
    my $header= <$VAL>;
    my %cols = getColumns($header, 1);
    my @fields =  qw / uid validated / ;
    foreach my $f (@fields){
        if (not exists $cols{$f}){
            die "Could not find required column '$f' in validation file!\n";
        }
    }
    while ( my $line = <$VAL> ){
        chomp $line;
        my @split = split("\t", $line); 
        $val{$split[ $cols{uid} ] } = $split[ $cols{validated} ] ;
    }
    close $VAL;
    return %val;
}
###########################################################
sub readPrimerFile{
    open (my $PRIMERS, $opts{primer_file}) 
      or die "Can't open primer file $opts{primer_file}: $!\n";
    my @prime = (); #create an array of hash refs with id, chr, start, end, f and r keys
    my $header = <$PRIMERS>;
    my %cols = getColumns($header); 
    my @fields =  qw / ID CHROM START END F R / ;
    foreach my $f (@fields){
        if (not exists $cols{$f}){
            die "Could not find required column '$f' in primers file!\n";
        }
    }
    while ( my $line = <$PRIMERS> ){
        chomp $line;
        my @split = split("\t", $line); 
        my %pr = map { $_ => $split[ $cols{$_} ] } @fields;
        push @prime, \%pr; 
    }
    close $PRIMERS;
    @prime = sort {   
            $a->{CHROM} cmp $b->{CHROM} ||
            $a->{START} <=> $b->{START} || 
            $a->{END} <=> $b->{END}     || 
            $a->{ID} cmp $b->{ID}
    } @prime;
    return @prime;
}
###########################################################
sub checkClinvarFile{
#returns columns hash of col name to col number
    my $cv = shift;
    if ($cv !~ /\.(b)*gz$/){
        print STDERR "ClinVar file ($cv) is missing a .gz extension - " .
            "attempting to compress with bgzip.\n";
        return compressClinVarTsv($cv); 
    }elsif( not -e "$cv.tbi"){
        print STDERR "No index found for ClinVar file ($cv). Attempting to index with tabix...\n";
        return indexClinVar($cv);
    }elsif( -M "$cv.tbi" > -M $cv){
        print STDERR "Tabix index is older than ClinVar file ($cv). Attempting to re-index with tabix...\n";
        return indexClinVar($cv);
    }else{
        my %col = getClinVarColumns($cv);
        return $cv, \%col;
    }
}
###########################################################
sub compressClinVarTsv{
    my $cv = shift;
    if (not `which bgzip`){
        die "Could not find bgzip executable - please install bgzip and ensure ".
            "it is in your PATH or compress and index $cv manually.\n";
    }
    my %columns = getClinVarColumns($cv);
    print STDERR "Compressing $cv with bgzip...\n";
    system("bgzip -c $cv > $cv.gz"); 
    checkExit($?);
    $cv = "$cv.gz";
    indexClinVar($cv, \%columns); 
    return ($cv, \%columns);
}
###########################################################
sub indexClinVar{
    my $cv = shift;
    my %columns = ();
    if (my $col = shift){
        %columns = %$col;
    }else{
        %columns = getClinVarColumns($cv);
    }
    my $seqcol = $columns{chrom} + 1;
    my $poscol = $columns{pos}   + 1;
    system("tabix -S 1 -s $seqcol -b $poscol -e $poscol $cv"); 
    checkExit($?);
    return %columns;
}
###########################################################
sub checkExit{
    my $exit = shift;
    return if not $exit;
    if ($exit == -1) {
        print "failed to execute: $!\n";
    }elsif ($exit & 127) {
        printf "command died with signal %d, %s coredump\n",
        ($exit & 127),  ($exit & 128) ? 'with' : 'without';
    }elsif ($exit) {
        printf "command exited with value %d\n", $exit >> 8;
    }
    die "Error executing command. Exiting.\n";
}
    
###########################################################
sub getClinVarColumns{
    my $cv = shift;
    my $CVAR; 
    if ($cv =~ /\.(b)*gz$/){
        $CVAR = new IO::Uncompress::Gunzip $cv, MultiStream => 1 
          or die "IO::Uncompress::Gunzip failed while opening $cv for reading: \n$GunzipError";
    }else{
        open ($CVAR, $cv) or die "Can't open $cv for reading header: $!\n";
    }
    my $header = <$CVAR>;
    my %columns = getColumns($header, 1);
    for my $c ( qw / 
                    chrom
                    pos
                    ref
                    alt
                    mut
                    clinical_significance
                    pathogenic
                    all_traits
                    all_pmids
                / ) { 
        if (not exists $columns{$c}){
            die "Required column ($c) not found in ClinVar file ($cv) header.\n";
        }
    }
    close $CVAR;
    return %columns;
}
###########################################################
sub getHgmdSearchArgs{
    return if not $opts{m};
    informUser("Checking HGMD vcf\n") if $opts{m};
    die "Header not ok for input ($opts{m}) "
      if not VcfReader::checkHeader( vcf => $opts{m} );
    return VcfReader::getSearchArguments($opts{m});
}
    
###########################################################
sub assessAndWriteVariant{
#identify transcript to report (make sure variant is functional and choose highest ranked transcript)
#write variant details to HGMD Excel sheet
#add var info to sample summary sheet and link to variant in main worksheet;
    my $line = shift;
    chomp ($line); 
    my @split = split("\t", $line); 
    #see if variant overlaps any variants in HGMD file
    my %min = VcfReader::minimizeAlleles(\@split);
    my %af_info_values  = ();
    if (%af_info_fields){ #check for annotateSnps.pl etc. frequencies
        %af_info_values = getAfInfoValues(\@split);
    }
    foreach my $al (sort {$a<=>$b} keys %min){
        writeToSheet(\@split, $min{$al}, \%af_info_values);
    }
}

###########################################################
sub getAfInfoValues{
    my $l = shift;
    my %values = ();
    foreach my $k (keys %af_info_fields){
        $values{$k} = VcfReader::getVariantInfoField($l, $k);
    }
    return %values;
}

###########################################################
sub alleleAboveMaf{
    my $i = shift; #1-based index of alt allele to assess
    my $af_values = shift; #hash ref of INFO fields to their values
    foreach my $k (keys %{$af_values}){
        next if not $af_values->{$k};
        next if $af_values->{$k} eq '.';
        my @split = split(",", $af_values->{$k}); 
        next if $split[$i] eq '.';
        if ($k eq "AS_G5" or $k eq "AS_G5A"){
            if ($af <= 0.05 and $split[$i] > 0){
                return 1;
            }
        }elsif ($k eq "AS_COMMON"){
            if ($af <= 0.01 and $split[$i] > 0){
                return 1;
            }
        }else{#should be a standard allele freq now
            if ($info_fields{$k}->{Type} eq 'Float' or $k eq 'AS_CAF'){
                return 1 if $split[$i] >= $af;
            }else{
                print STDERR "WARNING: Don't know how to parse INFO field: $k.\n";
            }
        }
    }
    return 0;
}

###########################################################
sub writeToSheet{
    my ($l, $var, $af_info) = @_;
    #split line, minimized variant hash, allele frequency INFO hash
    if (%af_info_fields){ #check for annotateSnps.pl etc. frequencies
       return if ( alleleAboveMaf($var->{ALT_INDEX} - 1, $af_info) );
    }
    #filter line if allele is too common
    if ($opts{a}){
        my %allele_counts = VcfReader::countAlleles
            (
                  line => $l,
                  minGQ => $min_gq,
            );
        my $total_allele_count = 0;
        foreach my $k (keys %allele_counts){
            $total_allele_count += $allele_counts{$k}; 
        }
        if ($total_allele_count > 0){
            if ($allele_counts{$var->{ALT_INDEX}}/$total_allele_count >= $opts{a}){
                print $FILTER_OUT join("\t", @$l) . "\n" if $opts{f};
                return;
            }
        }
    }
    my $var_class; # our designation for this variant
    my @row = (); #values to write out to excel sheet
    my @split_cells = (); #values to write in split cells spanning row
    my @primer_hits = (); #primers that could PCR variant if $opts{primer_file}

    #deal with VEP annotations
    my @get_vep =  
      qw /
            Symbol
            Gene
            Consequence
            Allele
            feature
            canonical
            hgvsc
            hgvsp
            exon
            intron
            polyphen
            sift
            condel
            DOMAINS
            Amino_acids
            protein_position
            ensp
            LoF
            LoF_Filter
            LoF_info
            LoF_flags

      /;

    my @vep_csq = VcfReader::getVepFields
    (
        line       => $l,
        vep_header => \%vep_fields,
        field      => \@get_vep,
    );
    my $ref      = VcfReader::getVariantField($l, 'REF');
    my @alts     = split(",", VcfReader::getVariantField($l, 'ALT'));
    my @vep_alts = VcfReader::altsToVepAllele
    (
        ref  => $ref,
        alts => \@alts,
    );
    my %alt_to_vep = ();
    @alt_to_vep{@alts} = @vep_alts;
    my @csq_to_rank = ();
    foreach my $csq (@vep_csq){ 
        #collect info for each transcript before selecting which to use in report
        #skip consequences for different alleles if variant site is multiallelic
        next if $csq->{allele} ne $alt_to_vep{ $var->{ORIGINAL_ALT} };
        #if we've provided a list of RefSeq ranks skip if this gene symbol is not listed
        if (keys %transcript_ranks){
            my $gene = uc($csq->{gene});
            next if not exists $transcript_ranks{$gene};
        }
        push @csq_to_rank , $csq;
    }

    my $is_dm = '';#flag for matching pathogenic HGMD or ClinVar (counts only once)
    my $is_other = '';#flag for other matching HGMD or ClinVar
    my $is_lof = '';
    my $is_damaging = '';

    my $csq_to_report = rankTranscriptsAndConsequences(\@csq_to_rank); 
    my $most_damaging_csq = getMostDamagingConsequence($csq_to_report);
    my @cadd = split(",", VcfReader::getVariantInfoField($l, "CaddPhredScore"));
    my $allele_cadd = $cadd[ ($var->{ALT_INDEX} -1) ];

    #collect HGMD and ClinVar database annotations if found
    my @h_matches = ();#hashes of hgmd matching variants
    #keys are: hgmd_id, disease, variant_class, gene_symbol, hgvs
    my @c_matches = ();#hases of clinvar matching variants
    #keys are: measureset_id, pathogenic, clinical_significance, all_traits, conflicted 
    @h_matches = getHgmdMatches($var);
    @c_matches = getClinvarMatches($var);

##############ACMG SCORING##################
#1.  if HC LoF = very_strong evidence - TODO - check pLI? check splice consequence?
#2a. if polyphen, SIFT and CADD predict damaging missense = supporting evidence
#2b. if in-frame indel if CADD predicts damaging = supporting evidence
#3a. if missense or inframe indel and same amino acid substitution as previously observed = strong evidence
#3b. if missense or inframe indel and different substituion of same residue = moderate evidence
#3c. if other type of variant but same variant has been previously reported = strong evidence
#5.  if absent from ExAC and EVS = moderate evidence 
#6.  if matches one of our 'rules' = strong evidence
#7.  TODO - if missense in a gene with a Z-score > 2 = supporting evidence
#8.  TODO - if Stop loss or run on frameshift = moderate
    my %pathogenic_criteria = 
    (
        very_strong => [], 
        strong      => [], 
        moderate    => [],
        supporting  => [],
        other       => [],
    );
    my %pathogenic_score = 
    (
        very_strong => 0, 
        strong      => 0, 
        moderate    => 0,
        supporting  => 0,
        other       => 0,
    );
    
    my %lofs = map {$_ => undef} qw /
        transcript_ablation  
        splice_acceptor_variant
        splice_donor_variant
        stop_gained
        frameshift_variant
        start_lost
    /;


    if (exists $lofs{$most_damaging_csq}){
        #check really is LOF
        if ($csq_to_report->{lof} and $csq_to_report->{lof} eq 'HC'){
            $pathogenic_score{very_strong}++;
            push @{$pathogenic_criteria{very_strong}}, 
               "High Confidence LoF";
            $is_lof = "HC_LoF";
        }elsif($csq_to_report->{lof} and $csq_to_report->{lof} eq 'LC'){
            my $f = $csq_to_report->{lof_filter} || '';
            push @{$pathogenic_criteria{strong}}, 
               "Low Confidence LoF: $f";
            $pathogenic_score{strong}++;
            $is_lof = "LC_LoF";
        }else{
            push @{$pathogenic_criteria{strong}}, 
               "Potential LoF ($most_damaging_csq)";
            $pathogenic_score{strong}++;
            $is_lof = "Potential_LoF";
        }
    }
    #TODO check stop losses or run ons
    
    #if same as previously reported DM = strong evidence
    foreach my $m (@h_matches){
        my $criteria;
        if ($m->{variant_class} eq 'DM'){
            $is_dm = "HGMD_DM";
            $criteria = 'strong';
        }else{
            $is_other = "HGMD_Other";
            $criteria = 'other';
        }
        push @{$pathogenic_criteria{$criteria}}, 
          join(":", "HGMD variant", 
                        map { $m->{$_} } 
                        qw /
                            hgmd_id
                            variant_class
                            disease
                            hgvsc
                            hgvsp
                        /
              );
    }
    foreach my $m (@c_matches ){
        my $criteria ;
        if ($m->{pathogenic} == 1 and $m->{conflicted} == 0 ){ 
            $is_dm ||= "ClinVarPathogenic";
            $criteria = 'strong';
        }else{
            $is_other = "ClinVarOther";
            $criteria = 'other';
        }
        push @{$pathogenic_criteria{$criteria}}, 
          join(":", "ClinVar variant", 
                    map { $m->{$_} } 
                    qw /
                        measureset_id
                        clinical_significance
                        all_traits
                        hgvsc
                        hgvsp
                    /
          );
    }
    if ($is_dm){
        $pathogenic_score{strong}++;
    }
     
    if ($most_damaging_csq eq 'missense_variant' or 
        $most_damaging_csq eq 'protein_altering_variant' or 
        $most_damaging_csq =~  /^inframe_(inser|dele)tion$/ 
    ){
        if ($most_damaging_csq eq 'missense_variant'){
            #in silico predictions add to supporting evidence
            if ($allele_cadd  >= 10 and 
                $csq_to_report->{polyphen} =~ /damaging/i and 
                $csq_to_report->{sift} =~ /deleterious/i
            ){
                $pathogenic_score{supporting}++;
                push @{$pathogenic_criteria{supporting}}, 
                    "Polyphen=$csq_to_report->{polyphen}, SIFT=$csq_to_report->{sift}, CADD > 10";
                $is_damaging = "damaging_$most_damaging_csq";
            }
        }else{
            if ($allele_cadd >= 10){
                $pathogenic_score{supporting}++;
                push @{$pathogenic_criteria{supporting}}, 
                    "CADD > 10";
                $is_damaging = "damaging_$most_damaging_csq";
            }
        } 
        #check if same amino acid change as previously reported variant
        my %criteria_matched = ();
        #keys are either 'moderate' or 'strong' to reflect whether same 
        # subtitution was observed (strong) or different substitution at
        # same residue (moderate)
        $search_handles{hgmd_aa}->execute
        (
            $csq_to_report->{feature},
            $csq_to_report->{protein_position},
        ) or die "Error searching 'HGMD_VEP' table in '$opts{t}': " . 
          $search_handles{hgmd_aa} -> errstr;
        while (my @db_row = $search_handles{hgmd_aa}->fetchrow_array()) {
            my ($hgmd_id, $feature, $consequence, $protein_position, $aa, $hgvsc, $hgvsp) = @db_row; 
            next if ($hgmd_id and grep {$_->{hgmd_id} eq $hgmd_id} @h_matches );
            my @s_csq = split("&", $consequence); 
            @s_csq = sort { $so_ranks{$a} <=> $so_ranks{$b} } @s_csq;
            if ($s_csq[0] ne 'missense_variant' and 
                $s_csq[0] ne 'protein_altering_variant' and 
                $s_csq[0] !~  /^inframe_(inser|dele)tion$/
            ){
                next;
            }
            my $criteria = 'moderate';
            my $desc = "same AA altered";
            if ($aa eq $csq_to_report->{amino_acids}){
                $criteria = 'strong';
                $desc = "same AA change";
            }
            $search_handles{hgmd_id}->execute($hgmd_id) 
              or die "Error searching 'HGMD' table in '$opts{t}': " . 
              $search_handles{hgmd_id} -> errstr;
            while (my ($vc, $disease) = $search_handles{hgmd_id}->fetchrow_array()) {
                if ($vc ne 'DM'){
                    $criteria = 'other';
                }
                push @{$pathogenic_criteria{$criteria}}, 
                  "$desc:HGMD_$hgmd_id:$vc:$disease:$hgvsc:$hgvsp";
                $criteria_matched{$criteria}++;
            }
        }
        $search_handles{clinvar_aa}->execute
        (
            $csq_to_report->{feature},
            $csq_to_report->{protein_position},
        ) or die "Error searching 'ClinVar_VEP' table in '$opts{t}': " . 
          $search_handles{clinvar_aa} -> errstr;
        while (my @db_row = $search_handles{clinvar_aa}->fetchrow_array()) {
            my ($clinvar_id, $feature, $consequence, $protein_position, $aa, $hgvsc, $hgvsp) = @db_row; 
            next if (grep {$_->{measureset_id} eq $clinvar_id} @c_matches );
            my @s_csq = split("&", $consequence); 
            @s_csq = sort { $so_ranks{$a} <=> $so_ranks{$b} } @s_csq;
            if ($s_csq[0] ne 'missense_variant' and 
                $s_csq[0] ne 'protein_altering_variant' and 
                $s_csq[0] !~  /^inframe_(inser|dele)tion$/
            ){
                next;
            }
            my $criteria = 'moderate';
            my $desc = "same AA altered";
            if ($aa eq $csq_to_report->{amino_acids}){
                $criteria = 'strong';
                $desc = "same AA change";
            }
            $search_handles{clinvar_id}->execute($clinvar_id) 
              or die "Error searching 'ClinVar' table in '$opts{t}': " . 
              $search_handles{clinvar_id} -> errstr;
            while (my ($path, $clinsig, $conflicted, $disease) = 
                    $search_handles{clinvar_id}->fetchrow_array()
            ) {
                if ($conflicted or not $path){
                    $criteria = 'other';
                }
                push @{$pathogenic_criteria{$criteria}}, 
                  "$desc:ClinVar_$clinvar_id:$clinsig:$disease:$hgvsc:$hgvsp";
                $criteria_matched{$criteria}++;
            }
        }
        foreach my $c (keys %criteria_matched){
            $pathogenic_score{$c}++ ;
        }
    }
               
    if (%af_info_fields){ #moderate support if absent from ExAC and EVS 
        my $missing_fields = 0;
        my $present_in_db = 0;
        foreach my $f 
        (qw /
            EVS_EA_AF
            EVS_AA_AF
            FVOV_AF_AFR
            FVOV_AF_AMR
            FVOV_AF_EAS
            FVOV_AF_FIN
            FVOV_AF_NFE
            FVOV_AF_SAS
        /){
            if (not exists $af_info_fields{$f}){
                $missing_fields++;
                last;
            }
            my @split = split(",", $af_info->{$f}); 
            if ($split[$var->{ALT_INDEX} -1] ne '.' and 
                $split[$var->{ALT_INDEX} -1] > 0
            ){
                $present_in_db++;
                last;
            }
        }
        if (not $present_in_db and not $missing_fields){
            $pathogenic_score{moderate}++;
            push @{$pathogenic_criteria{moderate}}, "Absent in ExAC and EVS";
        }
    }

    #TODO - check Z-score from ExAC if > 2 == supporting    
 
    if (exists $csq_to_report->{rule} ){
        $pathogenic_score{strong}++;
        push @{$pathogenic_criteria{strong}}, "Rules: $csq_to_report->{rule}";
    }elsif (exists $csq_to_report->{glyxy} ){
        $pathogenic_score{strong}++;
        push @{$pathogenic_criteria{strong}}, "GlyXY: $csq_to_report->{glyxy}";
    }
##############END OF ACMG SCORING##################
    ###ASSIGN $var_class
    if ($is_dm){
        $var_class = $is_dm;
    }elsif($is_lof){
        $var_class = $is_lof;
    }elsif(exists $csq_to_report->{rule}){
        $var_class = 'RuleMatched';
    }elsif (exists $csq_to_report->{glyxy} ){
        $var_class = 'GlyXY';
    }elsif($is_damaging){
        $var_class = $is_damaging;
    }elsif($is_other){
        $var_class = $is_other;
    }else{
        $var_class = 'Other';
    }
    
##############ADD VALUES TO ROW FROM SPREADSHEET##
    #choose sheet to write to
    my $s_name = classifyPathogenicity(\%pathogenic_score);
    if (@h_matches){
        foreach my $f 
        ( qw /
                hgmd_id
                disease
                variant_class
                gene_symbol
                hgvs
            /
        ){#add HGMD results to row, multiple values per field separated by commas
            my $s = join(",", map { $_->{$f} } @h_matches );
            push @row, $s;
        }
    }else{
        push @row, map {"-"} (1..5); 
    }
    
    #collect ClinVar database annotations if found
    if (@c_matches){
        foreach my $f 
        ( qw /
                measureset_id
                clinical_significance 
                all_traits 
                conflicted 
            /
        ){#add ClinVar results to row, multiple values per field separated by commas
            my $s = join(",", map { $_->{$f} } @c_matches );
            push @row, $s;
        }
    }else{
        push @row, map {"-"} (1..4); 
    }

    #get 'most damaging' variant found in transcripts, if same 'damaging' score
    # for multiple transcripts return the variant in the highest ranked transcript
    if ($opts{rules}){
        my $o = $csq_to_report->{rule};
        $o ||= '';
        push @row, $o;
    }
    if ($opts{t}){
        my $o = $csq_to_report->{overlap_features};
        $o ||= '';
        push @row, $o;
    }


    #add standard VCF fields from this allele only
    foreach my $f ( qw / CHROM ORIGINAL_POS ORIGINAL_REF ORIGINAL_ALT / ){
        push @row, $var->{$f};
    }
    push @row, VcfReader::getVariantField($l, 'ID');
    push @row, VcfReader::getVariantField($l, 'QUAL');
    push @row, VcfReader::getVariantField($l, 'FILTER');

    my @vep_fields = (qw / symbol feature consequence hgvsc hgvsp exon intron / );
    foreach my $f (@vep_fields){
        push @row, $csq_to_report->{$f};
    }

    push @row, $csq_to_report->{domains};
    push @row, $csq_to_report->{glyxy_pos};
    push @row, $csq_to_report->{domain_coords};

    foreach my $f (qw / lof lof_filter lof_info lof_flags polyphen sift condel / ){
        push @row, $csq_to_report->{$f};
    }
    if (exists $search_handles{et} ){
        push @row, getEtScore($csq_to_report); 
    }

    push @row, $allele_cadd;
    #add variant score/classifcaiton/info to beginning of row
    my $path_score = 0;
    my @score_string = ();
    my @criteria_string = ();
    my @cats = (
        qw /
            other
            supporting 
            moderate   
            strong      
            very_strong 
        /
        );
        for (my $i = $#cats; $i >= 0; $i--){
            push @score_string, "$cats[$i]: $pathogenic_score{$cats[$i]}";
            $path_score += $i * $pathogenic_score{$cats[$i]};
            if (@{$pathogenic_criteria{$cats[$i]}}){
                push @criteria_string, "$cats[$i]: " . join("|", @{$pathogenic_criteria{$cats[$i]}});
            }
        }
    unshift @row, join("\n", @criteria_string);
    unshift @row, join("\n", @score_string);
    unshift @row, $path_score;
    unshift @row, $var_class;
    my $uid_base = sprintf
        (
            "%s:%s-%s/%s-", 
            $var->{CHROM},  
            $var->{ORIGINAL_POS},
            $var->{ORIGINAL_REF},
            $var->{ORIGINAL_ALT},
        ); #we add sample IDS to this string to create UIDs for sample variants

    #search primers
    if (@primers){
        @primer_hits = searchPrimers($var);
    }
    #add sample info to new array of array refs to be written 
    # in split cells alongside global variant fields
    my %samp_gts = VcfReader::getSampleActualGenotypes
        (
              line => $l, 
              all => 1,
              sample_to_columns => \%samples_to_columns,
              minGQ => $min_gq,
        );
    my %samp_gqs = VcfReader::getSampleGenotypeField
        (
              line => $l, 
              field => "GQ",
              all => 1,
              sample_to_columns => \%samples_to_columns,
        );
    my %samp_pls = VcfReader::getSampleGenotypeField
        (
              line => $l, 
              field => "PL",
              all => 1,
              sample_to_columns => \%samples_to_columns,
        );

    my %samp_ads = (); 
    foreach my $s (keys %samples_to_columns){
        my @ads = VcfReader::getSampleAlleleDepths 
         (
              line => $l,
              sample => $s,
              sample_to_columns => \%samples_to_columns,
        );
        $samp_ads{$s} = \@ads;
    }    
    my $variant_has_valid_sample = 0;
    foreach my $s (
            sort {$samples_to_columns{$a} <=> $samples_to_columns{$b}} 
            keys %samples_to_columns
    ){
        my @alts = split(/[\/\|]/, $samp_gts{$s});
        if (grep { $_ eq $var->{ORIGINAL_ALT} } @alts ){ 
            my @ads = @{$samp_ads{$s}}; 
            my $depth = sum(@ads);
            if ($opts{d}){
                next if $opts{d} > $depth;
            }
            if ($opts{g}){
                eval "$opts{g} <= $samp_gqs{$s}" or next;
            }
            if ($opts{pl}){
                my @pls = split(",", $samp_pls{$s});
                next if $pls[0] < $opts{pl};
            }
            my $ab = 0;
            if ( $depth > 0){
                $ab = $ads[$var->{ALT_INDEX}]/$depth;
            }
            if (@{$opts{b}}){
                next if $ab < $opts{b}->[0];
                if (scalar @{$opts{b}} > 1){
                    next if $ab > $opts{b}->[1];
                }
            }
            my $uid = "$uid_base$s";
            my @sample_cells = ( $s, $samp_gts{$s}, join(",", @ads) , $ab, $samp_gqs{$s}, $samp_pls{$s},  $uid );
            if (@primers){
                if (@primer_hits){
                    push @sample_cells, join("/", @primer_hits); 
                }else{
                    push @sample_cells, '-';
                }
            }
            if (%validated){
                #search validations
                if (exists $validated{$uid}){
                    if ($validated{$uid} == 2){#did not validate - skip
                        next unless $opts{keep_unvalidated};
                    }
                    push @sample_cells, $validated{$uid};
                }else{
                    push @sample_cells, 0;
                }
            }
            $variant_has_valid_sample++;
            if ($opts{phenotype_file}){
                #search phenotypes
                foreach my $ph (@pheno_fields){
                    if (exists $phenotypes->{$s}){
                        push @sample_cells, $phenotypes->{$s}->{$ph};
                    }else{
                        push @sample_cells, '-';
                    }
                }
            }
            push @split_cells, \@sample_cells;
            {
                no warnings 'uninitialized';
                push @{$sample_vars{$s}->{$s_name}}, [$path_score, $allele_cadd, @sample_cells, $s_name, @row, ];
            }
        }
    }
    if (not $opts{n} or $variant_has_valid_sample){
        
        my $category = $s_name;
        $variant_counts{$category}++;
        if ($opts{1}){
            $s_name = 'Variants';
        }
        unshift @row, $category;
        if ($opts{x}){ #do not merge
            foreach my $s (@split_cells){
                my @full_line = (@row, @$s); 
                $xl_obj->writeLine
                (
                    line => \@full_line,
                    worksheet  => $sheets{$s_name},
                );
            }
        }else{
            $xl_obj->writeLine
            (
                line       => \@row, 
                worksheet  => $sheets{$s_name},
                succeeding => \@split_cells,
            );
        }
    }
}
###########################################################
sub classifyPathogenicity{
    my $p_hash = shift;
    #Pathogenic criteria
    if ($p_hash->{very_strong} >= 1){
        return 'Pathogenic';
    }
    if ($p_hash->{strong} >= 2){
        return 'Pathogenic';
    }
    if ($p_hash->{strong} >= 1){
        if ($p_hash->{moderate} >= 3 or 
            ($p_hash->{moderate} >= 2 and $p_hash->{supporting} >= 2) or 
            ($p_hash->{moderate} >= 1 and $p_hash->{supporting} >= 4) 
        ){
            return 'Pathogenic';
        }
    }

    #Likely pathogenic criteria
    if ($p_hash->{strong} >= 1){
        return 'Likely Pathogenic';
    }
    if ($p_hash->{moderate} >= 3){
        return 'Likely Pathogenic';
    }
    if ($p_hash->{moderate} >= 2 and $p_hash->{supporting} >= 2){
        return 'Likely Pathogenic';
    }
    if ($p_hash->{moderate} >= 1 and $p_hash->{supporting} >= 4){
        return 'Likely Pathogenic';
    }
    if ($p_hash->{moderate} >= 1 or $p_hash->{supporting} >= 1){
        return 'Uncertain Significance';
    }
    
    #at the moment we do not attempt to assign 'benign' status
    return 'Not Classified';
}


###########################################################
sub classifyPathogenicityAcmg{
    my $p_hash = shift;
    #Pathogenic criteria
    if ($p_hash->{very_strong} >= 1){
        if ($p_hash->{strong} >= 1 or 
            $p_hash->{moderate} >= 2 or 
            ($p_hash->{moderate} >= 1 and $p_hash->{supporting} >= 1) or 
            $p_hash->{supporting} >= 2 
        ){
            return 'Pathogenic';
        }
    }
    if ($p_hash->{strong} >= 2){
        return 'Pathogenic';
    }
    if ($p_hash->{strong} >= 1){
        if ($p_hash->{moderate} >= 3 or 
            ($p_hash->{moderate} >= 2 and $p_hash->{supporting} >= 2) or 
            ($p_hash->{moderate} >= 1 and $p_hash->{supporting} >= 4) 
        ){
            return 'Pathogenic';
        }
    }

    #Likely pathogenic criteria
    if ($p_hash->{very_strong} >= 1 and $p_hash->{moderate} >= 1){
        return 'Likely Pathogenic';
    }
    if ($p_hash->{strong} >= 1){
        if ($p_hash->{moderate} >= 1 or $p_hash->{supporting} >= 2){
            return 'Likely Pathogenic';
        }
    }
    if ($p_hash->{moderate} >= 3){
        return 'Likely Pathogenic';
    }
    if ($p_hash->{moderate} >= 2 and $p_hash->{supporting} >= 2){
        return 'Likely Pathogenic';
    }
    if ($p_hash->{moderate} >= 1 and $p_hash->{supporting} >= 4){
        return 'Likely Pathogenic';
    }
    
    #at the moment we do not attempt to assign 'benign' status
    #instead we classify as VUS       
    return 'Uncertain Significance';
}

###########################################################
sub getClinvarMatches{
    my $var = shift;
    my %clinvar = ();#keys are HGMD fields, values are array refs of values
    my @results = ();
    my @clinvar_fields = 
    ( qw /
            measureset_id
            pathogenic
            clinical_significance 
            all_traits 
            conflicted 
        /
    );
    $search_handles{clinvar_pos}->execute
    (
        $var->{CHROM}, 
        $var->{POS}, 
        $var->{REF}, 
        $var->{ALT}, 
    ) or die "Error searching 'ClinVar_VEP' table in '$opts{t}': " . 
      $search_handles{clinvar_pos} -> errstr;
    
    while (my @db_row = $search_handles{clinvar_pos}->fetchrow_array()) {
        my %clinvar = ();
        for (my $i = 0; $i < @db_row; $i++){
            $clinvar{$clinvar_fields[$i]} = $db_row[$i];
        }
        $search_handles{clinvar_hgvs}->execute($db_row[0]) 
          or die "Error searching 'ClinVar' table in '$opts{t}': " . 
          $search_handles{clinvar_hgvs} -> errstr;
        ($clinvar{hgvsc}, $clinvar{hgvsp}) = $search_handles{clinvar_hgvs}->fetchrow_array();
        push @results, \%clinvar;
    }
    return @results;
}

###########################################################
sub getHgmdMatches{
    my $var = shift;
    my @results = ();
    my @hgmd_fields = 
    ( qw /
            hgmd_id
            disease
            variant_class
            gene_symbol
            hgvs
        /
    );
    $search_handles{hgmd_pos}->execute
    (
        $var->{CHROM}, 
        $var->{POS}, 
        $var->{REF}, 
        $var->{ALT}, 
    ) or die "Error searching 'HGMD' table in '$opts{t}': " . 
      $search_handles{hgmd_pos} -> errstr;
    while (my @db_row = $search_handles{hgmd_pos}->fetchrow_array()) {
        my %hgmd = ();
        for (my $i = 0; $i < @db_row; $i++){
            $hgmd{$hgmd_fields[$i]} = $db_row[$i];
        }
        $search_handles{hgmd_hgvs}->execute($db_row[0]) 
          or die "Error searching 'HGMD' table in '$opts{t}': " . 
          $search_handles{hgmd_hgvs} -> errstr;
        ($hgmd{hgvsc}, $hgmd{hgvsp}) = $search_handles{hgmd_hgvs}->fetchrow_array();
        push @results, \%hgmd;
    }
    return @results;
}

###########################################################
sub getEtScore{
    #if more than one AA is altered return highest score
    my @scores = ();
    my $csq = shift;
    my ($p_start, $p_end) = split("-", $csq->{protein_position}); 
    $p_end ||= $p_start;
    my @aa = split("/", $csq->{amino_acids});
    return '' if @aa != 2;
    s/-// for @aa; #turn deleted AAs to empty strings
    for (my $i = $p_start; $i <= $p_end; $i++){
        my $j = $p_start - $i;
        last if ($j > length($aa[1]));
        my $wt = substr($aa[0], 0, 1); 
        my $mut = substr($aa[1], 0, 1); 
        if ($wt ne $mut){
            $search_handles{et}->execute
            (
                $csq->{feature}, 
                $i, 
                $wt,
                $mut,
            ) or die "Error searching 'EvolutionaryTrace' table in '$opts{t}': " . 
              $search_handles{et} -> errstr;
            my $row = 0;
            while (my $score = $search_handles{et}->fetchrow_array()){
                push @scores, $score if $score;
                if ($row == 1){
                    informUser("WARNING: Only expected one row from EvolutionaryTrace search!\n");
                }
                $row++;
            }
        }
    }
    my $max = max(@scores); 
    return $max if $max;
    return '';
}

###########################################################
sub searchPrimers{
#returns array of matching primer IDs
    my $var = shift;
    my @hits = (); 
    my $u = $#primers;
    my $l = 0;
    my $var_end = $var->{POS} + length($var->{REF}); 
    while ( $l <= $u ){
        my $i = int ( ( $u + $l ) / 2 ) ;
        if ($var->{CHROM} lt $primers[$i]->{CHROM}){
            $u = $i - 1;
        }elsif ($var->{CHROM} gt $primers[$i]->{CHROM}){
            $l = $i + 1;
        }else{#same chrom
            my $target_start = $primers[$i]->{START} + length( $primers[$i]->{F} ) + 50;
            my $target_end = $primers[$i]->{END} - length( $primers[$i]->{R} ) - 50;
                #require primers to be at least 50 bp away from target nucleotide
            if ($var->{POS} < $target_start){
                $u = $i -1;
            }elsif($var_end > $target_end){
                $l = $i + 1;
            }else{
                push @hits, $primers[$i]->{ID};
                #search for hits either site;
                for (my $j = $i - 1; $j >= 0; $j--){
                    my $t_start = $primers[$j]->{START} + length( $primers[$j]->{F} ) + 50;
                    my $t_end = $primers[$j]->{END} - length( $primers[$j]->{R} ) - 50;
                    if ($var->{POS} >= $t_start && $var_end <= $t_end){
                        push @hits, $primers[$j]->{ID};
                    }else{
                        last if $var_end < $t_start;
                    }
                } 
                for (my $j = $i + 1; $j < @primers; $j++){
                    my $t_start = $primers[$j]->{START} + length( $primers[$j]->{F} ) + 50;
                    my $t_end = $primers[$j]->{END} - length( $primers[$j]->{R} ) - 50;
                    if ($var->{POS} >= $t_start && $var_end <= $t_end){
                        push @hits, $primers[$j]->{ID};
                    }else{
                        last if $var->{POS} > $t_end;
                    }
                }
                return @hits;
            }
        }
    }
    return @hits;
}

###########################################################
sub alleleMatchesClinVar{
    my ($var, $chrom, $pos, $ref, $alt) = @_;
    #$var is a ref to a single entrey from minimized alleles hash
    #$line is a clinvar entry
    #returns 1 if it matches
    return 0 if $chrom ne $var->{CHROM}; 
    return 0 if $pos != $var->{POS};
    return 0 if $ref ne $var->{REF};
    return 0 if $alt ne $var->{ALT};
    return 1;
}
###########################################################
sub setupOutput{
    my @suffixes = (".vcf", ".txt");
    if (not $opts{o}){
        my ($out, $dir, $extension) = fileparse($opts{i}, @suffixes);
        $opts{o} = "$dir/$out.xlsx";
    }else{
        $opts{o} .= ".xlsx" if $opts{o} !~ /\.xlsx$/;
    }
#    $url_format = $xl_obj->createFormat(
#        color     => 'blue',
#        underline => 1,
#    );  
    if ($opts{1}){
        $xl_obj = TextToExcel->new( file=> $opts{o}, name => "Variants");
        $sheets{Variants} = 0;
        $header_formatting = $xl_obj->createFormat(bold => 1);
        writeHeader($sheets{Variants}, $headers{Variants});
    }else{
        $xl_obj = TextToExcel->new( file=> $opts{o}, name => "Pathogenic");
        $header_formatting = $xl_obj->createFormat(bold => 1);
        writeHeader($sheets{Pathogenic}, $headers{Variants});
        $sheets{Pathogenic} = 0;
        $sheets{"Likely Pathogenic"} = addSheet("Likely Pathogenic", $headers{Variants});
        $sheets{"Uncertain Significance"} = addSheet("Uncertain Significance", $headers{Variants});
        $sheets{"Not Classified"} = addSheet("Not Classified", $headers{Variants});
    }

    $sheets{SampleSummary} = addSheet("Sample Summary", $headers{sample});
    $sheets{MostDamaging} = addSheet("MostDamaging", $headers{mostdamaging});
        
    if ($opts{f}){
        open ($FILTER_OUT, ">$opts{f}") or die "Could not create filter output file \"$opts{f}\": $!\n";
        print $FILTER_OUT join("\n", @vhead) . "\n";
    }
}

###########################################################
sub getHeaders{
    my %h = ();

    @{$h{Variants}} =  ( #header for all variant sheets
        qw/
            Category
            Class
            Score
            ScoreBreakdown
            Criteria
            Hgmd_ID
            Disease
            HGMD_variant_class
            HGMD_Symbol
            HGVS
            ClinVar_ID
            ClinVarSig
            ClinVarTrait
            ClinVarConflicted
            Chrom
            Pos
            Ref
            Alt
            ID
            Qual
            Filter
            Symbol
            Feature
            Consequence 
            HGVSc 
            HGVSp 
            Exon
            Intron
            Domains
            DomainPosition
            DomainCoordinates
            LoF
            LoF_Filter
            LoF_info
            LoF_flags
            Polyphen
            SIFT
            Condel
            CADD
            Sample
            GT
            AD
            AB
            GQ
            PL
            UID
        /
    );
=cut
    @{$h{HGMD}} =  ( 
        qw / 
            index
            Hgmd_ID
            Disease
            variant_class
            HGMD_Symbol
            HGVS
            ClinVarSig
            ClinVarTrait
            Chrom
            Pos
            Ref
            Alt
            ID
            Qual
            Filter
            Symbol
            Feature
            Consequence 
            HGVSc 
            HGVSp 
            Domains
            Polyphen
            SIFT
            CADD
            Sample
            GT
            AD
            AB
            GQ
            UID
     /);
    @{$h{LOF}} =  ( 
        qw / 
            index
            ClinVarSig
            ClinVarTrait
            Chrom
            Pos
            Ref
            Alt
            ID
            Qual
            Filter
            Symbol
            Feature 
            Consequence 
            HGVSc 
            HGVSp 
            Domains
            LoF
            LoF_Filter
            LoF_info
            LoF_flags
            CADD
            Sample
            GT
            AD
            AB
            GQ
            UID
     /);
    
    @{$h{clinvar}} =  ( 
        qw / 
            index
            ClinVarSig
            ClinVarTrait
            Conflicted
            Chrom
            Pos
            Ref
            Alt
            ID
            Qual
            Filter
            Symbol
            Feature 
            Consequence 
            HGVSc 
            HGVSp 
            Domains
            Polyphen
            SIFT
            CADD
            Sample
            GT
            AD
            AB
            GQ
            UID
     /);

    @{$h{glyxy}} =  ( 
        qw / 
            index
            ClinVarSig
            ClinVarTrait
            Chrom
            Pos
            Ref
            Alt
            ID
            Qual
            Filter
            Symbol
            Feature 
            Consequence 
            HGVSc 
            HGVSp 
            Domains
            DomainPosition
            DomainCoordinates
            Polyphen
            SIFT
            CADD
            Sample
            GT
            AD
            AB
            GQ
            UID
     /);




    @{$h{missense}} =  ( 
        qw / 
            index
            ClinVarSig
            ClinVarTrait
            Chrom
            Pos
            Ref
            Alt
            ID
            Qual
            Filter
            Symbol
            Feature 
            Consequence 
            HGVSc 
            HGVSp 
            Domains
            Polyphen
            SIFT
            CADD    
            Sample
            GT
            AD
            AB
            GQ
            UID
     /);
=cut

    @{$h{sample}} =  (  
            "Sample",
            "Pathogenic",
            "Likely Pathogenic",
            "Uncertain Significance",
            "Not Classified",
    );
    @{$h{mostdamaging}} =  ( #header for all variant sheets
        qw/
            Sample
            GT
            AD
            AB
            GQ
            PL
            UID
            Category
            Class
            Score
            ScoreBreakdown
            Criteria
            Hgmd_ID
            Disease
            variant_class
            HGMD_Symbol
            HGVS
            ClinVar_ID
            ClinVarSig
            ClinVarTrait
            ClinVarConflicted
            Chrom
            Pos
            Ref
            Alt
            ID
            Qual
            Filter
            Symbol
            Feature
            Consequence 
            HGVSc 
            HGVSp 
            Exon
            Intron
            Domains
            DomainPosition
            DomainCoordinates
            LoF
            LoF_Filter
            LoF_info
            LoF_flags
            Polyphen
            SIFT
            Condel
            CADD
        /
    );

    my $md_spl = 0;#colu no. to add primers or validated columns to mostdamaging sheet
    $md_spl++ until $h{mostdamaging}->[$md_spl] eq 'Category'; 
        #this means we don't have to hardcode the column no., 
        # meaning if we edit the header we still insert prior to the Hgmd_ID column

    my $v_spl = 0; #column no. to add uniprot/cdd domain info to variant sheets
    $v_spl++ until $h{Variants}->[$v_spl] eq 'Chrom'; 
        #this means we don't have to hardcode the column no., 
        # meaning if we edit the header we still insert prior to the Chrom column

    if (exists $search_handles{et}){
        splice (@{$h{Variants}}, -8, 0, "EvolutionaryTraceScore"); 
        splice (@{$h{mostdamaging}}, -1, 0,  "EvolutionaryTraceScore");
    }
    if ($opts{primer_file}){
        push @{$h{Variants}}, "primers";
        splice (@{$h{mostdamaging}}, $md_spl++, 0, "primers");
    }
    if ($opts{validations_file}){
        push @{$h{Variants}}, "validated?(1=yes,2=no,0=not_done)";
        splice (@{$h{mostdamaging}}, $md_spl++, 0, "validated?(1=yes,2=no,0=not_done)");
    }
    if ($opts{phenotype_file}){
        foreach my $ph (@pheno_fields){
            push @{$h{Variants}}, $ph;
            splice (@{$h{mostdamaging}}, $md_spl++, 0, $ph); 
        }
    }
    if ($opts{rules}){
        splice (@{$h{Variants}}, $v_spl++, 0, "RuleMatched"); 
        splice (@{$h{mostdamaging}}, 14 + $md_spl++, 0, "RuleMatched"); 
    }
    if ($opts{t}){
        splice (@{$h{Variants}}, $v_spl++, 0, "Uniprot/CDD_Features"); 
        splice (@{$h{mostdamaging}}, 14 + $md_spl++, 0, "Uniprot/CDD_Features"); 
    }
    return %h;
}
###########################################################
sub writeHeader{
    my $sheet = shift; 
    my $header = shift;
    $xl_obj->writeLine(line => $header, format => $header_formatting, worksheet => $sheet);
}

###########################################################
sub addSheet{
    my ($name, $header) = @_; 
    my $sheet = $xl_obj->addWorksheet($name);
    writeHeader($sheet, $header);
    return $sheet;
}

###########################################################
    
###########################################################
sub rankTranscriptsAndConsequences{
    my $csq_array = shift;#ref to array of VEP consequences 
    @$csq_array = rankConsequences(@$csq_array); 
    my $most_damaging = getMostDamagingConsequence($csq_array->[0]) ;
    @$csq_array = rankTranscripts(@$csq_array); 
    if (%rules){
        if ( my $matched = checkRules($csq_array) ){
            return $matched;
        }
    }elsif($opts{t}){
        #if not checking rules just use getCddAndUniprotOverlappingFeatures 
        #to annotate any overlapping features which will be added to $csq hash
        foreach my $csq (@$csq_array){
            getCddAndUniprotOverlappingFeatures($csq);
        }
    }
    if ($most_damaging =~ /missense_variant/ or 
        $most_damaging =~ /protein_altering_variant/ or  
        $most_damaging =~ /inframe_(inser|dele)tion/
    ){
        #check if is mutation of glycine in collagen triple helix and return
        if (my $glyxy_csq = checkCollagenDomain($csq_array)){
            return $glyxy_csq;
        }
    }
    return first { $_->{consequence} =~ $most_damaging } @$csq_array;
}

###########################################################
sub getCddAndUniprotOverlappingFeatures{
    #returns a ref to an array of hashes of overlapping features
    my @hits = (); 
    return \@hits if not $dbh;
    my $csq = shift;
    my $uniprot = $enst_xref{$csq->{feature}}->{uniprot}; 
    return \@hits if not $uniprot;
    return \@hits if not $csq->{ensp};#skip non-coding
    return \@hits if not $csq->{amino_acids};#skip any non-coding variant
    return \@hits if (split("/", $csq->{amino_acids}) < 2); 
    return \@hits if not $csq->{protein_position};
    my ($p_start, $p_end) = split("-", $csq->{protein_position}); 
    $p_end ||= $p_start;
    #get overlapping uniprot features
    $search_handles{uniprot}->execute($uniprot, $p_start, $p_end)
      or die "Error searching 'uniprot' table in '$opts{t}': " . 
      $search_handles{uniprot} -> errstr;
    while (my @row = $search_handles{uniprot}->fetchrow_array()) {
        my $hash = 
        { 
            type    => "uniprot", 
            start   => $row[2],
            end     => $row[3],
            feature => $row[4],
            note    => $row[5],
            grch37pos => $row[6],
            grch38pos => $row[7],
        }; 
        push @hits, $hash;
    }
    
    $search_handles{cdd}->execute($uniprot, $p_start, $p_end)
      or die "Error searching 'cdd' table in '$opts{t}': " . 
      $search_handles{cdd} -> errstr;
    while (my @row = $search_handles{cdd}->fetchrow_array()) {
        my $type = '';
        if ($row[2] eq 'Feature'){
            $type = 'cdd_feature';
        }elsif ($row[2] eq 'Hit'){
            $type = 'cdd_hit';
        }else{
            informUser("WARNING: Do not understand ResultType field '$row[2]' in cdd table of $opts{t} - ignoring.\n");
            next;
        }
        my $hash = 
        { 
            type      => $type, 
            feature   => $row[3],
            residues  => $row[4],#residues are only present in 'Feature' types, not 'Hit'
            start     => $row[5],
            end       => $row[6],
            grch37pos => $row[7],
            grch38pos => $row[8],
        }; 
        push @hits, $hash;
    }
    my @hit_summary = () ;
    foreach my $h (@hits){
        push @hit_summary, "$h->{type},$h->{feature},$h->{start}-$h->{end}";
    }
    if (@hit_summary){
        $csq->{overlap_features} = join("/", @hit_summary); 
    }
    return \@hits;
}

###########################################################
sub checkRules{
    my $csq_array = shift;
#ref to array of VEP consequences 
#should be sorted in order of preferred transcripts
#return first consequence (if any) that matches a rule
    for (my $i = 0; $i < @$csq_array; $i++){
        my $uniprot = $enst_xref{$csq_array->[$i]->{feature}}->{uniprot}; 
        next if not $uniprot;
        next if not $rules{$uniprot}; 
        my $feats = getCddAndUniprotOverlappingFeatures($csq_array->[$i]);
    #ref to arrays of hashes of overlapping cdd/uniprot features from getCddAndUniprotOverlappingFeatures method
        if ( my @rules = assessRules($csq_array->[$i], $feats, $uniprot) ){
            $csq_array->[$i]->{rule} = join(";", @rules);
            return $csq_array->[$i];
        }
    }
}

###########################################################
sub assessRules{
    my $csq = shift;
    my $feats_list = shift;
#ref of arrays of hashes of overlapping cdd/uniprot features from getCddAndUniprotOverlappingFeatures method
    my $uniprot = shift;
    my @rules = ();
    foreach my $r (@{ $rules{$uniprot} } ){ 
        if ($r->{mutations} ne 'any'){
            my @classes = split(",", $r->{mutations});
            my @s_csq = split("&", $csq->{consequence} );
            my $m = 0;
            foreach my $s (@s_csq){
                $m++ if grep { $_ eq $s } @classes;
            }
            next if not $m;
        }
        if ( $r->{type} eq 'cdd' ){
            if ( my $match = assessCddRule($r, $csq, $feats_list) ){
                push @rules, $match;
            }
        }elsif( $r->{type} eq 'uniprot' ){
            if ( my $match = assessUniprotRule($r, $csq, $feats_list) ){
                push @rules, $match;
            }
        }elsif( $r->{type} eq 'residues' ){
            if ( my $match = assessResiduesRule($r, $csq,) ){
                push @rules, $match;
            }
        }else{
            informUser("WARNING: Do not understand rule of type '$r->{type}'!\n");
        }
    } 
    return @rules;
}

###########################################################
sub assessCddRule{
    my ($rule, $csq, $feats_list) = @_;
    my ($p_start, $p_end) = split("-", $csq->{protein_position}); 
    $p_end ||= $p_start;
    my @aa = split ("/", $csq->{amino_acids} ) ;
    s/-// for @aa; #turn deleted AAs to empty strings
    my @matched_rules = ();
    foreach my $f (@$feats_list){
        #all entries in @$feats_list overlap our variant
        next if lc($f->{feature}) ne lc($rule->{feature});
        if ($f->{type} eq 'cdd_feature'){
        #if a feature we want to check if mutation alters one of the
        #specific feature residues
            if (my @feature_residues_altered 
              = checkFeatureResidues
                (
                    \@aa, 
                    $f, 
                    $p_start, 
                    $p_end
                )
            ){
                push @matched_rules, @feature_residues_altered;
            }
        }elsif ($f->{type} eq 'cdd_hit'){
            if (defined $rule->{positions}){
                if (subCoordAltered($f, $rule->{positions}, \@aa, $p_start, $p_end)){
                    push @matched_rules, "$f->{type}:$f->{feature}($f->{start}-$f->{end})";
                }
            }else{
                push @matched_rules, "$f->{type}:$f->{feature}($f->{start}-$f->{end})";
            }
        }
    }
    return join("/", @matched_rules); 
}

###########################################################
sub subCoordAltered{
    my ($f, $pos_s, $aas, $p_start, $p_end) = @_;
    my @sub_coord = split(",", $pos_s); 
    foreach my $sc (@sub_coord){
        my $coord;
        if ($sc < 0 ){
            $coord = $f->{end} + $sc + 1;
        }else{
            $coord = $f->{start} + $sc - 1;
        }
        if (residueAltered($aas, $p_start, $p_end, $coord)){
            return 1;
        }
    }
    return 0;
}

###########################################################
sub residueAltered{
    my ($aas, $p_start, $p_end, $pos) = @_;
    my @wt_aa =  split ("", $aas->[0]); 
    my @mut_aa =  split ("", $aas->[1]); 
    for ( my $i = 0; $i < @wt_aa; $i++ ){
        my $wt_pos = $p_start + $i;
        next if $wt_pos < $pos;
        return 0 if $wt_pos > $pos;
        return ($i >= @mut_aa or $mut_aa[$i] ne $wt_aa[$i]);
    }
    return 0;
}

###########################################################
sub checkFeatureResidues{
    my ($aas, $f, $p_start, $p_end) = @_;
    my @residues = split(/\,/, $f->{residues}); 
    my @matched_rules = ();
    my @wt_aa =  split ("", $aas->[0]); 
    my @mut_aa =  split ("", $aas->[1]); 
    foreach my $residue (@residues){
        my ($res, $pos);
        if ($residue =~ /^([A-Z])(\d+)$/){
            ($res, $pos) = ($1, $2);
            for ( my $i = 0; $i < @wt_aa; $i++ ){
            #this should handle instances where change is a substitution
            # or deletion
            # do not know how to handle insertions
                my $wt_pos = $p_start + $i;
                next if $wt_pos < $pos;
                last if $wt_pos > $pos;
                if ($wt_aa[$i] eq $res){
                    if ($i >= @mut_aa or $mut_aa[$i] ne $res){
                        #mutation has altered feature residue
                        push @matched_rules, "$f->{type}:$f->{feature}$res$pos";
                    }
                }else{
                    informUser("WARNING: $f->{feature} feature residue '$res$pos' not matched ($pos).\n");
                }
            } 
        }elsif ($residue =~ /^([A-Z])(\d+)-([A-Z])(\d+)$/){
            my ($res1, $start, $res2, $end)  = ($1, $2, $3, $4);
            for ( my $i = 0; $i < @wt_aa; $i++ ){
            #this should handle instances where change is a substitution
            # or deletion
            # do not know how to handle insertions
                my $wt_pos = $p_start + $i;
                next if $wt_pos < $start;
                last if $wt_pos > $end;
                if ($i >= @mut_aa or $mut_aa[$i] ne $wt_aa[$i]){
                    #mutation has altered feature residue
                    push @matched_rules, "$f->{type}:$f->{feature}$res1$start-$res2$end";
                }
            }
        }else{
            informUser("ERROR: Do not know how to parse CDD feature residue '$residue' - skipping.\n"); 
            next;
        }
    }
    return @matched_rules;
}

###########################################################
sub assessUniprotRule{
    my ($rule, $csq, $feats_list) = @_;
    my @matched_rules = ();
    my ($p_start, $p_end) = split("-", $csq->{protein_position}); 
    $p_end ||= $p_start;
    my @aa = split ("/", $csq->{amino_acids} ) ;
    s/-// for @aa; #turn deleted AAs to empty strings
    foreach my $f (@$feats_list){
        #all entries in @$feats_list overlap our variant
        next if $f->{type} ne 'uniprot'; 
        next if lc($f->{feature}) ne lc($rule->{feature});
        if (defined $rule->{positions}){
            if (subCoordAltered($f, $rule->{positions}, \@aa, $p_start, $p_end)){
                push @matched_rules, "$f->{type}:$f->{feature}($f->{start}-$f->{end})";
            }
        }else{
            push @matched_rules, "$f->{type}:$f->{feature}($f->{start}-$f->{end})";
        }
    }
    return join("/", @matched_rules); 
}

###########################################################
sub assessResiduesRule{
    my ($rule, $csq) = @_;
    my ($p_start, $p_end) = split("-", $csq->{protein_position}); 
    $p_end ||= $p_start;
    my @aa = split ("/", $csq->{amino_acids} ) ;
    s/-// for @aa; #turn deleted AAs to empty strings
    my @matched_rules = ();
    my @wt_aa =  split ("", $aa[0]); 
    my @mut_aa =  split ("", $aa[1]); 
    my @coords = split(",", $rule->{feature}); 
    foreach my $c (@coords){
        my ($r_start, $r_end) = split("-", $c); 
        $r_end ||= $r_start;
        next if $r_start > $p_end or $r_end < $p_start;
        for ( my $i = 0; $i < @wt_aa; $i++ ){
            my $pos = $p_start + $i;
            last if $pos > $p_end;
            next if $pos < $p_start;
            if ($i >= @mut_aa or $wt_aa[$i] ne $mut_aa[$i]){
                push @matched_rules, "Residues:$c";
            }
        }
    }
    my %seen = ();
    @matched_rules = grep {! $seen{$_}++ } @matched_rules;
    return join("/", @matched_rules); 
}

###########################################################
sub checkCollagenDomain{
# only applicable to missense and inframe indels
# returns first VEP consequence with a missense altering a Gly 
# in a collagen triple helix or an inframe indel that is alters
# a number of amino acids not divisible by 3
    my $csq_array = shift;#ref to array of VEP consequences 
    foreach my $c (@$csq_array){
        my $dom_hash;
        my $gxy_frame = 0;
        my $gxy_length;
        if (not $opts{s}){#if not using the --scan_gxy option
            next if not $c->{domains};
            my @domains = split ("&", $c->{domains}); #domains variant overlaps
            if (grep { /Pfam_domain:PF01391/i } @domains){
                if ($opts{verbose}){
                    informUser("Found variant in collagen triple helix\n");
                    informUser("Checking domain sequence using Ensembl REST...\n");
                }
        #get coordinates of domains to find Gly-X-Y pattern using ensembl REST API
                #my $seq_hash  = ensRestQuery("$server/sequence/id/$c->{ensp}?"); 
                my $rest_url = "$server/overlap/translation/$c->{ensp}?";
                my $pfam_ar = ensRestQuery($rest_url);
                if (ref $pfam_ar ne 'ARRAY'){
                    die "Required array reference from Ensembl REST query: $rest_url\n" 
                }
                $dom_hash = findOverlappingDomain($pfam_ar, "PF01391", $c);
                
                # CHECK SEQ TO MAKE FIND 'FRAME' of GLY-X-Y repeat 
                my $seq_hash = getProteinSequence($c->{ensp}); 
                $dom_hash->{seq} = substr(
                                    $seq_hash->{seq}, 
                                    $dom_hash->{start} -1,  
                                    $dom_hash->{end} - $dom_hash->{start} + 1, 
                ); 
                #find the first repeat of 5 or more Gly-X-Ys 
                # -- TO DO - more sophisticated HMM perhaps?
                if ($opts{verbose}){
                    informUser("domain $dom_hash->{id}: $dom_hash->{start}-$dom_hash->{end} - $dom_hash->{seq}\n");
                    informUser("frame: $gxy_frame\n");
                }
            }
        }else{
            #scan sequence ourselves for GXY repeats
            next if not $c->{ensp};#skip non-coding
            next if $c->{symbol} !~ /^COL/;#skip non-collagens
            next if not $c->{amino_acids};#skip any non-coding variant
            my $seq_hash = getProteinSequence($c->{ensp}); 
            $dom_hash = findGlyXY($seq_hash->{seq}, $c); 
            if ($dom_hash and $opts{verbose}){
                informUser("Found putative Gly-X-Y domain in $c->{symbol} ($c->{ensp}) $dom_hash->{start}-$dom_hash->{end}:\n$dom_hash->{seq}\n");
            }
        }#limitation at the moment - does not allow for deletion spanning more than one GlyXY domains
        if ($dom_hash){
            $gxy_length =  1 + $dom_hash->{end} - $dom_hash->{start}; 
            if ($dom_hash->{seq} =~ /(G[A-Z]{2}){5,}/){
                $gxy_frame = $-[0] % 3;
                $gxy_length -= $gxy_frame;
            }else{
                die "Could not find Gly-X-Y repeat in PF01391 domain seq:\n$dom_hash->{seq}\n\n";
            }
            my @aa = split ("/", $c->{amino_acids} ) ;
            s/-// for @aa; #turn deleted AAs to empty strings
            if (length($aa[0]) == length($aa[1])){
                #check whether an essential glycine has been altered
                if (essentialGlyAltered(\@aa, $c, $dom_hash->{start} + $gxy_frame, $dom_hash->{end})){
                    my $gxy_pos = 1 + $c->{protein_position} - $dom_hash->{start}; 
                    $c->{glyxy_pos} = "$gxy_pos/$gxy_length";
                    $c->{glyxy} = 1;
                    $c->{domain_coords} = "$dom_hash->{id}: $dom_hash->{start}-$dom_hash->{end}"; 
                    return $c;
                }
            }else{
                my ($p_start, $p_end) = split("-", $c->{protein_position}); 
                my ($ref, $alt);
                ($ref, $alt, $p_start) = simplifyIndel($aa[0], $aa[1], $p_start);
                $p_end = $p_start + length($ref) - 1;
                $p_end = $p_end >= $p_start ? $p_end : $p_start;#fix in case length of $ref is 0
                my $diff = length($aa[0]) - length($aa[1]); 
                if ($diff > 0){#deletion
                    #check which portion of an indel lies within domain in case only partial overlap
                    my $dp_start = $p_start >= $dom_hash->{start} ? $p_start : $dom_hash->{start};
                    my $dp_end   = $p_end   <= $dom_hash->{end}   ? $p_end   : $dom_hash->{end};
                    if ($dp_start != $p_start){
                        my $trim = $dp_start - $p_start;
                        substr($aa[0], 0, $trim, ""); #remove beginning portion that does not lie in domain
                        substr($aa[1], 0, $trim, ""); #remove beginning portion that does not lie in domain
                    }
                    if ($dp_end != $p_end){
                        my $trim = $dp_end - $p_end;
                        $aa[0] = substr($aa[0], 0, $trim ); #remove end portion that does not lie in domain
                        $aa[1] = substr($aa[1], 0, $trim ); #remove end portion that does not lie in domain
                    }
                    $diff = length($aa[0]) - length($aa[1]); 
                }
                #check if insertion/deletion is divisible by 3 
                #if not divisible by 3 then triple helix broken
                if ($diff % 3){
                    $c->{glyxy} = 1;
                    $c->{domain_coords} = "$dom_hash->{id}: $dom_hash->{start}-$dom_hash->{end}"; 
                    return $c;
                }
                # if divisible by 3 check if a pos that should be a 
                # glycine has been altered
                if (essentialGlyAltered(\@aa, $c, $dom_hash->{start} + $gxy_frame, $dom_hash->{end})){
                    $c->{glyxy} = 1;
                    my $start_distance = $p_start > $dom_hash->{start} ? 1 + $p_start - $dom_hash->{start} : 1;
                    my $end_distance   = $p_end   < $dom_hash->{end}   ? 1 +  $p_end  - $dom_hash->{start} : "";
                    $c->{glyxy_pos} = "$start_distance-$end_distance/$gxy_length";
                    $c->{domain_coords} = "$dom_hash->{id}: $dom_hash->{start}-$dom_hash->{end}"; 
                    return $c;
                }
            }
        }
    }
}

###########################################################
sub findGlyXY{
    my ($seq, $csq) = @_; 
    my @gxys = scanForGlyXY($seq);
    my ($p_start, $p_end) = split("-", $csq->{protein_position}); 
    $p_end ||= $p_start; 
    foreach my $hash (@gxys){
        if ($hash->{start} <= $p_start and $hash->{end} >= $p_start){
            #variant lies within this domain
            return $hash;
        }elsif ($hash->{start} <= $p_end and $hash->{end} >= $p_end){
            return $hash;
        }
    }
    return undef;
}

###########################################################
sub scanForGlyXY{
    my $seq = shift;
    my @glyxys = ();
    my $n = 0;
    while ($seq =~ /((G[A-Z]{2}){5,})/g){
        my %dom = (); 
        $n++;
        $dom{start} = $-[0] + 1;
        $dom{end} = $-[0] + length($1);
        $dom{id} = "glyxy-$n";
        push @glyxys, \%dom;
    }
    #merge hashes within 6 aa of each other to allow for
    #occasional non-gly-x-y triplets
    my $prev_hash = $glyxys[0];
    my @merged = ();
    for (my $i = 1; $i < @glyxys; $i++){
        my $gap = $glyxys[$i]->{start} - $prev_hash->{end};
        if ($gap == 7 or $gap == 4){
            $prev_hash->{end} = $glyxys[$i]->{end};
        }else{
            $prev_hash->{seq} = substr(
                              $seq,
                              $prev_hash->{start} -1,  
                              $prev_hash->{end} - $prev_hash->{start} + 1, 
            );
            push @merged, $prev_hash;
            $prev_hash = $glyxys[$i];
        }
    }
    if ($prev_hash){
        $prev_hash->{seq} = substr(
                          $seq,
                          $prev_hash->{start} -1,  
                          $prev_hash->{end} - $prev_hash->{start} + 1, 
        );
        push @merged, $prev_hash ;
    }
    return @merged;
}
        


###########################################################
sub essentialGlyAltered{
    #return 1 if Gly at pos 0, 3, 6, etc. of domain altered
    my ($aa, $c, $dom_start, $dom_end) = @_;
    # ref to amino acid array (ref and alt), VEP csq hash ref 
    # and domain details hash ref
    my ($p_start, $p_end) = split("-", $c->{protein_position}); 
    my @gly_idxs = grep { substr($aa->[0], $_, 1) eq "G" } 0..(length($aa->[0]));
    foreach my $i (@gly_idxs){
        my $pos = $i + $p_start ;#actual protein pos of this Gly
        next if $pos < $dom_start;
        last if $pos > $dom_end;
        my $dist = $pos - $dom_start;#distance of Gly from domain start
        next if $dist % 3; #not an essential Gly if not at pos 0 of 3 aa repeat
        if ($i > length($aa->[1])){#Essential Gly deleted(?)
            return 1;
        }
        if (substr($aa->[1], $i, 1) ne 'G'){ # Essential Gly altered
            return 1;
        }
    }
    #if insertion, check we have Glys in the right positions
    if (length($aa->[0]) < length($aa->[1])){
        my $frame = ($p_start - $dom_start) % 3 ;
        for (my $i = 0; $i < length($aa->[1]); $i += 3){
            next if $i < length($aa->[0]); #only check the remaining portion of seq not in the Ref AAs
            my $res = substr($aa->[1], $i + $frame, 1);
            if ($res ne 'G'){
                return 1;
            }
        }
    }
    return 0;
}

###########################################################
sub simplifyIndel{
    my ($ref, $alt, $p_start) = @_;
    while (length($ref) > 1 and length($alt) > 1){
        while ( (substr($ref, -1, 1)) eq (substr($alt, -1, 1)) 
                and (length($ref) > 0) and (length($alt) > 0)
        ){
            substr($ref, -1, 1, "");
            substr($alt, -1, 1, "");
        }
        while ( (substr($ref, 0, 1)) eq (substr($alt, 0, 1)) 
                and (length($ref) > 0) and (length($alt) > 0)
        ){
            substr($ref, 0, 1, "");
            substr($alt, 0, 1, "");
            $p_start++;
        }
    }
    return ($ref, $alt, $p_start);
}
###########################################################
sub findOverlappingDomain{
    my ($pfam_ar, $id, $csq) = @_;
    my ($p_start, $p_end) = split("-", $csq->{protein_position}); 
    $p_end ||= $p_start; 
    foreach my $hash (@$pfam_ar){
        next if $hash->{id} ne $id;
        next if $hash->{seq_region_name} ne $csq->{ensp};
        if ($hash->{start} <= $p_start and $hash->{end} >= $p_start){
            #variant lies within this domain
            return $hash;
        }elsif ($hash->{start} <= $p_end and $hash->{end} >= $p_end){
            #variant lies within this domain
            return $hash;
        }
    }
    die "No overlap found with $id domain for $csq->{hgvsc}/$csq->{hgvsp} in REST database\n";
}
###########################################################
sub getProteinSequence{
    my $ensp = shift;
    if (not exists $seq_cache{$ensp}){
        my $rest_url = "$server/sequence/id/$ensp";
        $seq_cache{$ensp} = ensRestQuery($rest_url);
        die "No sequence returned from REST query: $rest_url\n" if not $seq_cache{$ensp}->{seq};
    }
    return $seq_cache{$ensp};

}
###########################################################
sub ensRestQuery{
    my $url = shift;
    my $response = $http->get($url, {
          headers => { 'Content-type' => 'application/json' }
    });
    die "Ensembl REST query ('$url') failed!\n" unless $response->{success};
    if(length $response->{content}) {
      return decode_json($response->{content});
    }
    die "No content for Ensembl REST query ('$url')!\n";
}
        
    
###########################################################
sub rankTranscripts{
    my @vars = @_;#array of hashes of VEP consequences
    return sort { getTranscriptsRanks( $a->{gene}, $a->{feature} ) <=> getTranscriptsRanks( $b->{gene}, $b->{feature} ) } @vars;
}
###########################################################
sub getTranscriptsRanks{
    my $symbol = shift;
    my $transcript = shift; 
    return -1 if not exists $transcript_ranks{$symbol};
    return -1 if not exists $transcript_ranks{$symbol}->{$transcript};
    return $transcript_ranks{$symbol}->{$transcript};
}

###########################################################
sub setMutationRules{
    return if not $opts{rules};
    open (my $RULES, $opts{rules}) or die "Cannot open rules file '$opts{rules}': $!\n";
    my $header = <$RULES>; 
    my %col = getColumns($header); 
    foreach my $c (
     qw /
		Uniprot
		CddFeatureType
		UniprotFeatureType
		Coordinates
		MutationType
        / 
    ){
        if (not exists $col{$c}){
            die "Required columns '$c' not found in rules file '$opts{rules}!\n";
        }
    }
    while (my $line = <$RULES>){
        chomp $line;
        my @split = split("\t", $line);
        #this allows for multiple rules per line
        if ($split[$col{CddFeatureType}]){
            my $r = { 
                      type      => "cdd",
                      feature   => $split[$col{CddFeatureType}],
                      mutations => $split[$col{MutationType}],
                      positions => $split[$col{PositionType}],
                    };
            push @{ $rules{$split[0]} } , $r;
        }
        if ($split[$col{UniprotFeatureType}]){
            my $r = { 
                      type      => "uniprot",
                      feature   => $split[$col{UniprotFeatureType}],
                      mutations => $split[$col{MutationType}],
                      positions => $split[$col{PositionType}],
                    };
            push @{ $rules{$split[0]} } , $r;
        }
        if ($split[$col{Coordinates}]){
            my $r = { 
                      type      => "residues",
                      feature   => $split[$col{Coordinates}],
                      mutations => $split[$col{MutationType}],
                      positions => $split[$col{PositionType}],
                    };
            push @{ $rules{$split[0]} } , $r;
        }
    }
}

###########################################################
sub getColumns{
    #returns a hash of column names to 0-based column number
    my ($header, $to_lower, $delimiter) = @_;
    $delimiter ||= "\t"; 
    chomp (my @head = split($delimiter, $header)); 
    my $n = 0;
    my %columns = (); 
    if ($to_lower){
        %columns = map { lc($_) => $n++ } @head;
    }else{
        %columns = map { $_ => $n++ } @head;
    }
    return %columns;
}


###########################################################
sub rankConsequences{
    my @vars = @_;#array of hashes of VEP consequences
    return sort { 
        $so_ranks{getMostDamagingConsequence($a)} <=> 
        $so_ranks{getMostDamagingConsequence($b)} 
    } @vars;
    
}

###########################################################
sub getMostDamagingConsequence{
    my $csq = shift;#hash ref to VEP consequences for single transcript/feature
    my @s_csq = split("&", $csq->{consequence} );
    @s_csq = sort { $so_ranks{$a} <=> $so_ranks{$b} } @s_csq;
    return $s_csq[0];
}
    
###########################################################
sub setConsequenceRanks{
    my @so_terms = qw /
        transcript_ablation  
        splice_acceptor_variant
        splice_donor_variant
        stop_gained
        frameshift_variant
        stop_lost
        start_lost
        transcript_amplification
        inframe_insertion
        inframe_deletion
        missense_variant
        protein_altering_variant
        splice_region_variant
        incomplete_terminal_codon_variant
        stop_retained_variant
        synonymous_variant
        coding_sequence_variant
        mature_miRNA_variant
        5_prime_UTR_variant
        3_prime_UTR_variant
        non_coding_transcript_exon_variant
        intron_variant
        NMD_transcript_variant
        non_coding_transcript_variant
        upstream_gene_variant
        downstream_gene_variant
        TFBS_ablation
        TFBS_amplification
        TF_binding_site_variant
        regulatory_region_ablation
        regulatory_region_amplification
        feature_elongation
        regulatory_region_variant
        feature_truncation
        intergenic_variant 
    /;
    my $n = 0;
    %so_ranks = map { $_ => $n++ } @so_terms; 
}

###########################################################
sub getClnSigCodes{
    return (
        0 => "Uncertain significance",
        1 => "not provided",
        2 => "Benign",
        3 => "Likely benign",
        4 => "Likely pathogenic",
        5 => "Pathogenic",
        6 => "drug response",
        7 => "histocompatibility",
        255 => "other"
    );
}

#################################################
sub informUser{
    my $msg = shift;
    my $time = strftime( "%H:%M:%S", localtime );
    if ($progressbar){
        $progressbar->message( "[INFO - $time] $msg" );
    }else{
        print STDERR "[INFO - $time] $msg";
    }
}
#################################################

=head1 NAME

clinSummarizerTaad.pl - assess known/potentially pathogenic mutations for TAAD

=head1 SYNOPSIS

        clinSummarizerTaad.pl -i [vcf file] -m [HGMD mart converted vcf file] [options]
        clinSummarizerTaad.pl -h (display help message)
        clinSummarizerTaad.pl --manual (display manual page)

=cut

=head1 ARGUMENTS

=over 8

=item B<-i    --input>

Input VCF file (prefiltered on public databases for allele frequency).

=item B<-o    --output>

Output xlsx file. Defaults to input file with .xlsx extension added.

=item B<-n    --no_blanks>

Do not output variants which do not have at least one sample passing the variant criteria.

=item B<-t    --transcript_database>

sqlite database of transcripts and cross references created with dbCreator.pl 

=item B<-b    --allele_balance>

Min and optional max alt allele ratio per sample call.

=item B<-d    --depth>

Optional min depth for sample call.

=item B<-a    --allele_cutoff>

Remove if allele is present in this proportion or more calls.

=item B<-f    --filter_output>

Optional output file for calls filtered on allele_cutoff.

=item B<-r    --rest_server>

URL of REST server to use if not the default (http://grch37.rest.ensembl.org).

=item B<-g    --gq>

Min GQ quality for calls.

=item B<-p    --progress>

Display a progress bar.

=item B<--verbose>

Show verbose progress information.

=item B<-h    --help>

Display help message.

=item B<--manual>

Show manual page.

=back 

=cut

=head1 DESCRIPTION

Creates an xlsx spreadsheet with worksheets for TAAD mutations based on categorisations such as known HGMD mutations, ClinVar pathogenic/likely pathogenic mutations, loss of function mutations, mutations of Glycines in Collagen triple helices etc.

=head1 AUTHOR

David A. Parry

=head1 COPYRIGHT AND LICENSE

Copyright 2015  David A. Parry

This program is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. This program is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details. You should have received a copy of the GNU General Public License along with this program. If not, see <http://www.gnu.org/licenses/>.

=cut
