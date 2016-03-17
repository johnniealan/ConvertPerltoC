#!/usr/bin/perl
# Filename:	convertPerl
# Author:	Johnnie Alan (johnniealan@gmail.com)
# Description:	Create a perl executable by embedding the script in C code
use strict;
use ExtUtils::Embed;

##################################################
# Setup the variables
##################################################
my $PROGNAME = $0; $PROGNAME =~ s|.*/||;

my $LIBPERL = '/usr/lib/libperl.a';	# For static linking hack

##################################################
# Filters
##################################################
sub attempt_use {
	my $save = $SIG{__DIE__};
	$SIG{__DIE__} = 'ignore';
	### could also do "require $_[0]; import $_[0]"
	eval("use $_[0]");
	my $ret = $@ ? 0 : 1;
	$SIG{__DIE__} = $save;
	$ret;
}

sub bleach {
	my ($scriptP) = @_;
	usage("Can't -bleach, PAR::Filter::Bleach not installed")
		unless attempt_use "PAR::Filter::Bleach";
	PAR::Filter::Bleach->apply($scriptP); 
}

##################################################
# Usage
##################################################
sub fatal {
	foreach my $msg (@_) { print STDERR "[$PROGNAME] ERROR:  $msg\n"; }
	exit(-1);
}

sub usage {
	foreach my $msg (@_) { print STDERR "ERROR:  $msg\n"; }
	print STDERR <<USAGE;

Usage:\t$PROGNAME [-d] <script>
  Convert a perl script to (embedded) C code

  -key <str>         Specify key for encode/decode of embedded script
  -o <file>          Save output to specified file.
  -bleach            Also bleach code using PAR::Filter::Bleach (if avail)
  -d                 Debug mode (show actions)
                       Uses:  $LIBPERL

USAGE
	exit -1;
}

sub parse_args {
	my $opt = {
		key => 'somekey',
	};
	while (my $arg=shift(@ARGV)) {
		if ($arg =~ /^-h$/) { usage(); }
		if ($arg =~ /^-d$/) { $MAIN::DEBUG=1; next; }
		if ($arg =~ /^-o$/) { $opt->{out} = shift @ARGV; next; }
		if ($arg =~ /^-bleach$/) { $opt->{bleach} = 1; next; }
		if ($arg =~ /^-./) { usage("Unknown option: $arg"); }
		usage("Too many scripts specified [$arg and $opt->{script}]") if $opt->{script};
		$opt->{script}=$arg;
	}
	usage("No script defined") unless $opt->{script};

	$opt;
}

sub debug {
	return unless $MAIN::DEBUG;
	foreach my $msg (@_) { print STDERR "[$PROGNAME] $msg\n"; }
}

##################################################
# C code
##################################################
sub Cheader {
	my ($opt) = @_;

	my @inc;
	push(@inc, qw (EXTERN.h perl.h XSUB.h)) unless $opt->{block};
	push(@inc, qw (stdlib.h string.h sys/ioctl.h net/if.h));

	print C <<TOP;
/* **************************************************
 *  C wrapper for perl, created by $PROGNAME
 *  Author: Johnnie J. Alan
 *  Company: ALC
 * ************************************************** */
TOP

	foreach my $inc ( @inc ) {
		print C "#include <$inc>\n";
	}

 	return if $opt->{block};

	# Dynaloader time
	my $dyna = `perl -MExtUtils::Embed -e xsinit -- -o -`;
	print C $dyna;
}

sub Cmain {
	my ($opt) = @_;

	my $block = $opt->{block} || "block";
	my ($hostcheck,$hostcheckvars) = ("","");

	print C <<"ENDDECODE";

void
decode(char *block, char *key, int len) {
	int keylen = strlen(key);
	int i;

	if (keylen==0) return;

	for (i=0; i<len; i++) {
		block[i] -= key[i%keylen];
		block[i] %= 0xff;
	}
}
ENDDECODE

	print C <<"ENDMAIN" unless $opt->{block};

int
main(int argc, char **argv, char **env) {
$hostcheckvars
	PerlInterpreter *my_perl;

	// Modify this code to put the key somewhere external for more protection
	char *key = "$opt->{key}";

	// Args  ['','-e','','--',@ARGV]
	int pargc = 3+argc;
	char **parg = calloc(pargc+2, (sizeof(char*)));
	// Need to strdup (at least parg[1]) so that we can modify $0
	parg[0] = strdup(""); parg[1] = strdup("-e"); parg[2] = strdup("");  parg[3] = strdup("--");
	for(pargc=4;pargc<3+argc;pargc++) {
		parg[pargc] = argv[pargc-3];
	}
$hostcheck
	decode($block,key,$opt->{len});
	my_perl = perl_alloc();
	perl_construct(my_perl);
	if (perl_parse(my_perl, xs_init, pargc, parg, (char **)NULL)) {
		fprintf(stderr,"Trouble opening perl parser\\n");
		return -1;
	}

	eval_pv($block, G_VOID);

	perl_destruct(my_perl);
	perl_free(my_perl);

	fflush(stdout);

	return 0;
}
ENDMAIN
}

##################################################
# Building
##################################################
sub mySys {
	my (@cmd) = @_;
	print "@cmd\n" if $MAIN::DEBUG;
	system(@cmd);
	fatal("Error running [@cmd]") if $?;
}

sub compileCommand {
	my ($opt,$c) = @_;

	my $out = $opt->{exe} || 'a.out';

	my $ccopts = ccopts(0);
	my $ldopts = ldopts(0);
	if ($opt->{static}) {
		if (-f $LIBPERL) {
			$ldopts =~ s/ -lperl / $LIBPERL /;
		} else {
			print STDERR "[ERROR] Couldn't find \$LIBPERL [$LIBPERL]\n";
		}
	}
	$opt->{compile} = "gcc -std=gnu89 -o $out $c $ccopts $ldopts";
}

sub compile {
	my ($opt,$c) = @_;

	return unless $opt->{exe};
	mySys($opt->{compile});
	print "Exe: $opt->{exe}\n";
}

##################################################
# Main code
##################################################
sub main {
	my $opt = parse_args();

	my $c = $opt->{out};
	unless ($c) {
		$c = $opt->{script};
		$c = "stdin" if $c eq '-';
		$c =~ s/\.p.?$//;
		$c .= ".c";
	}

	compileCommand($opt,$c);

	my $script;
	open(FILE,"<$opt->{script}") || usage("Couldn't open script [$opt->{script}]");
	while(<FILE>) { $script .= $_; }
	close FILE;

	# Fix $0 (so it's not '-e')
	# Caused a segfault until I found out that $0 couldn't be 'const char'
	# https://rt.perl.org/Public/Bug/Display.html?id=44129
	$script = "BEGIN {\$0=\$^X;}\n".$script;

	$script = join("\n",@{$opt->{pre}}).$script if $opt->{pre};

	# Apply filters
	bleach(\$script) if $opt->{bleach};

	open(C,">$c") || usage("Couldn't write C source [$c]");
	
	Cheader($opt);
	
	my $block = $opt->{block} || "block";
	# char block[] = {0x...,0x0};
	print C "char ${block}[] = {\n  ";
	
	my @key = map { ord($_) } split('', $opt->{key});

	my $cnt=0;
	sub chOut {
		my ($ch) = @_;
		my $x = ord($ch);
		$x += $key[$cnt%($#key+1)] if @key;
		$x %= 0xff;
		printf C "0x%0.2x,",$x;
		print C "\n  " unless ++$cnt%14;
	}

	#while(read(FILE,$ch,1)) { chOut($ch); }	# Old way, read->write w/out filters
	my $ch;
	while(ord($ch = substr($script,0,1,''))) {
		chOut($ch);
		$opt->{len}++;
	}

	print C "0};\n";

	Cmain($opt);

	close(C);
	print STDERR "Out: $c\n" unless $opt->{exe} && $opt->{script} eq '-';

	compile($opt,$c);
	unlink($c) if $opt->{exe} && $opt->{script} eq '-';
}
main();
