# Functions for turning SpamAssassin filtering on or off on a per-domain basis

sub init_spam
{
$domain_lookup_cmd = "$module_config_directory/lookup-domain.pl";
$procmail_spam_dir = "$module_config_directory/procmail";
$spam_config_dir = "$module_config_directory/spam";
$quota_spam_margin = 5*1024*1024;
}

sub require_spam
{
return if ($require_spam++);
&foreign_require("procmail", "procmail-lib.pl");
&foreign_require("spam", "spam-lib.pl");
}

sub check_depends_spam
{
if (!$_[0]->{'mail'}) {
	# Mail must be enabled for spam filtering to work!
	return $text{'setup_edepspam'};
	}
if ($config{'mail_system'} == 5) {
	# Not implemented for VPopMail
	return $text{'setup_edepspamvpop'};
	}
return undef;
}

# setup_spam(&domain)
# Adds the master procmail entry for domain-specific spam filtering, plus an
# include file for this domain.
sub setup_spam
{
&$first_print($text{'setup_spam'});
&require_spam();

# Add the procmail entry to get the VIRTUALMIN variable
local @recipes = &procmail::get_procmailrc();
local ($r, $gotvirt, $gotdef);
foreach $r (@recipes) {
	if ($r->{'type'} eq '=' &&
	    $r->{'action'} =~ /^VIRTUALMIN=/) {
		$gotvirt++;
		}
	elsif ($r->{'name'} eq "DEFAULT") {
		$gotdef++;
		}
	}
if (!$gotvirt) {
	# Need to add entries to lookup the domain, and run it's include file
	&lock_file($procmail::procmailrc);
	local $var1 = { 'flags' => [ 'w', 'i' ],
			'conds' => [ ],
			'type' => '=',
		        'action' => "VIRTUALMIN=|$domain_lookup_cmd \$LOGNAME" };
	local $testcmd = &has_command("test") || "test";
	local $var2 = { 'flags' => [ ],
			'conds' => [ [ "?", "$testcmd \"\$VIRTUALMIN\" != \"\"" ] ],
			'block' => "INCLUDERC=$procmail_spam_dir/\$VIRTUALMIN",
		      };
	if ($gconfig{'os_type'} eq 'solaris') {
		# Need to call sh as shell explicitly
		$var2->{'conds'} =
			[ [ "?", "sh -c \"$testcmd '\$VIRTUALMIN' != ''\"" ] ];
		}

	# If the procmailrc file is empty, add at the end.
	# If there is a TRAP variable, add after it (so we do logging properly)
	# Otherwise, add at the top
	if (@recipes) {
		# Has some recipes .. check if there is a TRAP
		local ($trap, $aftertrap);
		for(my $i=0; $i<@recipes; $i++) {
			if ($recipes[$i]->{'name'} eq 'TRAP') {
				$trap = $recipes[$i];
				$trapafter = $recipes[$i+1];
				}
			}
		if ($trapafter) {
			# Add before the recipe that is after TRAP
			&procmail::create_recipe_before($var1, $trapafter);
			&procmail::create_recipe_before($var2, $trapafter);
			}
		elsif ($trap) {
			# Nothing after TRAP, so just add at end
			&procmail::create_recipe($var1);
			&procmail::create_recipe($var2);
			}
		else {
			# Just add at start
			&procmail::create_recipe_before($var1, $recipes[0]);
			&procmail::create_recipe_before($var2, $recipes[0]);
			}
		}
	else {
		&procmail::create_recipe($var1);
		&procmail::create_recipe($var2);
		}
	&foreign_require("cron", "cron-lib.pl");
	&cron::create_wrapper($domain_lookup_cmd, $module_name,
			      "lookup-domain.pl");
	&unlock_file($procmail::procmailrc);
	}

# Build spamassassin command to call
local $cmd = &spamassassin_client_command($_[0]);

# Create the domain's include file, to run SpamAssassin
if (!-d $procmail_spam_dir) {
	&lock_file($procmail_spam_dir);
	&make_dir($procmail_spam_dir, 0755);
	&set_ownership_permissions(undef, undef, 0755, $procmail_spam_dir);
	&unlock_file($procmail_spam_dir);
	}
local $spamrc = "$procmail_spam_dir/$_[0]->{'id'}";
&lock_file($spamrc);
local $recipe0 = { 'name' => 'DROPPRIVS',	# Run all commands as user
		   'value' => 'yes' };
local $recipe1 = { 'flags' => [ 'f', 'w' ],	# Call spamassassin
		   'conds' => [ ],
		   'type' => '|',
		   'action' => $cmd,
		 };
local ($varon, $recipe2, $varoff);
if ($config{'spam_delivery'}) {
	$varon = { 'name' => 'SPAMMODE', 'value' => 1 };
	$recipe2 = { 'flags' => [ ],		# Forward spam to destination
		     'conds' => [ [ '', '^X-Spam-Status: Yes' ] ],
		     'action' => $config{'spam_delivery'} };
	$varoff = { 'name' => 'SPAMMODE', 'value' => 0 };
	}
&procmail::create_recipe($recipe0, $spamrc);
&procmail::create_recipe($recipe1, $spamrc);
if ($recipe2) {
	&procmail::create_recipe($varon, $spamrc);
	&procmail::create_recipe($recipe2, $spamrc);
	&procmail::create_recipe($varoff, $spamrc);
	}

&set_ownership_permissions(undef, undef, 0755, $spamrc);
&unlock_file($spamrc);

# Create the spamassassin config directory for the domain
if (!-d $spam_config_dir) {
	&lock_file($spam_config_dir);
	&make_dir($spam_config_dir, 0755);
	&set_ownership_permissions(undef, undef, 0755, $spam_config_dir);
	&unlock_file($spam_config_dir);
	}
local $spamdir = "$spam_config_dir/$_[0]->{'id'}";
&lock_file($spamdir);
&make_dir($spamdir, 0755);
&set_ownership_permissions(undef, undef, 0755, $spamdir);
&unlock_file($spamdir);

# Link all files in the default directory (/etc/mail/spamassassin) to
# the domain's directory
&create_spam_config_links($_[0]);

# Create the config file for this server
&lock_file("$spamdir/virtualmin.cf");
&open_tempfile(TOUCH, ">$spamdir/virtualmin.cf", 0, 1);
&print_tempfile(TOUCH, "whitelist_from $d->{'emailto'}\n");
&close_tempfile(TOUCH);
&set_ownership_permissions($_[0]->{'uid'}, $_[0]->{'gid'}, 0755,
			  "$spamdir/virtualmin.cf");
&unlock_file("$spamdir/virtualmin.cf");

# Whitelist all domain mailboxes
if ($config{'spam_white'}) {
	$d->{'spam_white'} = 1;
	&update_spam_whitelist($d);
	}

# Setup automatic spam clearing
local ($cmode, $cnum) = split(/\s+/, $tmpl->{'spamclear'});
if ($cmode eq 'days' || $cmode eq 'size') {
	&save_domain_spam_autoclear($_[0], { $cmode => $cnum });
	}

&$second_print($text{'setup_done'});
}

# spamassassin_client_command(&domain, [client])
# Returns the command for calling spamassassin in some domain, plus args
sub spamassassin_client_command
{
local ($d, $client) = @_;
local $spamid = $d->{'parent'} || $d->{'id'};
$client ||= $config{'spam_client'};
local $cmd = &has_command($client);
if ($client eq 'spamc') {
	$cmd .= " -d $config{'spam_host'}" if ($config{'spam_host'});
	$cmd .= " -s $config{'spam_size'}" if ($config{'spam_size'});
	}
else {
	$cmd .= " --siteconfigpath $spam_config_dir/$spamid";
	}
return $cmd;
}

# validate_spam(&domain)
# Make sure the domain's procmail config file exists
sub validate_spam
{
local ($d) = @_;
local $spamrc = "$procmail_spam_dir/$d->{'id'}";
return &text('validate_espamprocmail', "<tt>$spamrc</tt>") if (!-r $spamrc);
local $spamdir = "$spam_config_dir/$d->{'id'}";
return &text('validate_espamconfig', "<tt>$spamdir</tt>") if (!-d $spamdir);
&require_spam();
local @recs = &procmail::parse_procmail_file($spamrc);
local $cmd = $spam::config{'spamassassin'};
local $found;
foreach my $r (@recs) {
	$found++ if ($r->{'action'} =~ /\Q$cmd\E|spamc|spamassassin/);
	}
return &text('validate_espamcall', "<tt>$spamrc</tt>") if (!$found);
return undef;
}

# setup_default_delivery()
# Adds or removes a rule at the end of /etc/procmailrc delivering to $DEFAULT,
# depending on the config setting
sub setup_default_delivery
{
&require_spam();
&lock_file($procmail::procmailrc);
local @recipes = &procmail::get_procmailrc();
my ($gotdef, $gotorgmail, $gotdel, $gotdrop);
foreach my $r (@recipes) {
	if ($r->{'action'} eq '$DEFAULT' && !@{$r->{'conds'}}) {
		$gotdel = $r;
		}
	}

# The rule to deliver to $DEFAULT is needed to prevent users from creating
# their own .procmailrc files
if ($config{'default_procmail'} && !$gotdel) {
	# Append default delivery rule
	my $rec = { 'flags' => [ ],
		    'conds' => [ ],
		    'action' => '$DEFAULT' };
	&procmail::create_recipe($rec);
	}
elsif (!$config{'default_procmail'} && $gotdel) {
	# Remove default delivery rule
	&procmail::delete_recipe($gotdel);
	}

# Find the DEFAULT variable setting
@recipes = &procmail::get_procmailrc();
foreach my $r (@recipes) {
	if ($r->{'name'} eq 'DEFAULT') {
		$gotdef = $r;
		}
	}

# The DEFAULT destination needs to be set to match the mail server, as procmail
# will deliver to /var/mail/USER by default
local ($dir, $style, $mailbox, $maildir) = &get_mail_style();
local $maildef = $dir ? "$dir/\$LOGNAME" :
		 $maildir ? "\$HOME/$maildir/" :
		 $mailbox ? "\$HOME/$mailbox" : undef;
if ($gotdef) {
	# Update default delivery definition
	$gotdef->{'value'} = $maildef;
	&procmail::modify_recipe($gotdef);
	}
else {
	# Create default delivery definition
	my $rec = { 'name' => 'DEFAULT',
		    'value' => $maildef };
	if (@recipes) {
		&procmail::create_recipe_before($rec, $recipes[0]);
		}
	else {
		&procmail::create_recipe($rec);
		}
	}

# Find the ORGMAIL variable
@recipes = &procmail::get_procmailrc();
foreach my $r (@recipes) {
	if ($r->{'name'} eq 'ORGMAIL') {
		$gotorgmail = $r;
		}
	}

# Same for the ORGMAIL destination, to prevent delivery falling back to
# /var/mail/XXX in an over-quota situation
if ($gotorgmail) {
	# Update default delivery rule
	$gotorgmail->{'value'} = $maildef;
	&procmail::modify_recipe($gotorgmail);
	}
else {
	# Create default delivery rule
	my $rec = { 'name' => 'ORGMAIL',
		    'value' => $maildef };
	if (@recipes) {
		&procmail::create_recipe_before($rec, $recipes[0]);
		}
	else {
		&procmail::create_recipe($rec);
		}
	}

# Re-get the default delivery receipe, and DROPPRIVS
$gotdel = undef;
@recipes = &procmail::get_procmailrc();
foreach my $r (@recipes) {
	if ($r->{'action'} eq '$DEFAULT' &&
	    !@{$r->{'conds'}}) {
		$gotdel = $r;
		}
	elsif ($r->{'name'} eq 'DROPPRIVS') {
		$gotdrop = $r;
		}
	}

# DROPPRIVS needs to be set to yes to force delivery as the correct user. This
# must be done before the rule that delivers to $DEFAULT, or at the end of the
# file.
if (!$gotdrop) {
	my $rec = { 'name' => 'DROPPRIVS',
		    'value' => 'yes' };
	if ($gotdel) {
		# Add before default rule
		&procmail::create_recipe_before($rec, $gotdel);
		}
	else {
		# Add at end
		&procmail::create_recipe($rec);
		}
	}

&unlock_file($procmail::procmailrc);
}

# enable_procmail_logging()
# Configure Procmail to log to /var/log/procmail.log, and setup logrotate
# for that directory.
sub enable_procmail_logging
{
&require_spam();
&lock_file($procmail::procmailrc);
local @recipes = &procmail::get_procmailrc();
local ($gotlog, $gottrap);
foreach my $r (@recipes) {
	if ($r->{'name'} eq 'LOGFILE') {
		$gotlog = 1;
		}
	if ($r->{'name'} eq 'TRAP') {
		$gottrap = 1;
		}
	}
if (!$gotlog) {
	# Add LOGFILE variables
	my $rec0 = { 'name' => 'LOGFILE',
		     'value' => $procmail_log_file };
	&procmail::create_recipe_before($rec0, $recipes[0]);
	}
if (!$gottrap) {
	# Add TRAP, which specifies a command to output logging info about
	# the email after delivery
	my $rec1 = { 'name' => 'TRAP', 'value' => $procmail_log_cmd };
	&procmail::create_recipe_before($rec1, $recipes[0]);
	}
&unlock_file($procmail::procmailrc);

# For any domains with spam or virus filtering enabled, add SPAMMODE and
# VIRUSMODE procmail variables so that the logger knows what kind of destination
# email ended up at
foreach my $d (&list_domains()) {
	next if (!$d->{'spam'});
	local $spamrc = "$procmail_spam_dir/$d->{'id'}";
	local @recipes = &procmail::parse_procmail_file($spamrc);
	local ($spamrec, $spamrecafter, $gotspammode);
	local $i = 0;
	foreach my $r (@recipes) {
		if ($r->{'name'} eq 'SPAMMODE') {
			$gotspammode = 1;
			}
		elsif ($r->{'conds'}->[0]->[1] eq '^X-Spam-Status: Yes') {
			# Found place to insert
			$spamrec = $r;
			$spamrecafter = $recipes[$i+1];
			last;
			}
		$i++;
		}
	if ($spamrec && !$gotspammode) {
		local $varon = { 'name' => 'SPAMMODE', 'value' => 1 };
		local $varoff = { 'name' => 'SPAMMODE', 'value' => 0 };
		if ($spamrecafter) {
			&procmail::create_recipe_before($varoff, $spamrecafter,
							$spamrc);
			}
		else {
			&procmail::create_recipe($varoff, $spamrc);
			}
		&procmail::create_recipe_before($varon, $spamrec, $spamrc);
		}

	# Do the same for viruses
	next if (!$d->{'virus'});
	local @recipes = &procmail::parse_procmail_file($spamrc);
	local ($clamrec, $clamafter, $gotclammode);
	local $i = 0;
	foreach my $r (@recipes) {
		if ($r->{'name'} eq 'VIRUSMODE') {
			$gotclammode = 1;
			}
		elsif ($r->{'action'} =~ /^\Q$clam_wrapper_cmd\E/) {
			# Insert after this one
			$clamrec = $recipes[$i+1];
			$clamrecafter = $recipes[$i+2];
			}
		$i++;
		}
	if ($clamrec && !$gotclammode) {
		local $varon = { 'name' => 'VIRUSMODE', 'value' => 1 };
		local $varoff = { 'name' => 'VIRUSMODE', 'value' => 0 };
		if ($clamrecafter) {
			&procmail::create_recipe_before($varoff, $clamrecafter,
							$spamrc);
			}
		else {
			&procmail::create_recipe($varoff, $spamrc);
			}
		&procmail::create_recipe_before($varon, $clamrec, $spamrc);
		}
	}

# Copy the log writer command to /etc/webmin
&copy_source_dest("$module_root_directory/procmail-logger.pl",
		  $procmail_log_cmd);
&set_ownership_permissions(undef, undef, 0755, $procmail_log_cmd);

if ($config{'logrotate'} && &foreign_installed("logrotate")) {
	# Add logrotate section, if needed
	&require_logrotate();
	local $log = &get_logrotate_section($procmail_log_file);
	if (!$log) {
		local $parent = &logrotate::get_config_parent();
		local $lconf = { 'file' => &logrotate::get_add_file(),
				 'name' => [ $procmail_log_file ] };
		$lconf->{'members'} = [
				{ 'name' => 'rotate',
				  'value' => $config{'logrotate_num'} || 5 },
				{ 'name' => 'daily' },
				{ 'name' => 'compress' },
				];
		&lock_file($lconf->{'file'});
		&logrotate::save_directive($parent, undef, $lconf);
		&flush_file_lines($lconf->{'file'});
		&unlock_file($lconf->{'file'});
		}
	}
}

# modify_spam(&domain, &olddomain)
# Doesn't have to do anything
sub modify_spam
{
}

# delete_spam(&domain)
# Just remove the domain's procmail config file
sub delete_spam
{
&$first_print($_[0]->{'virus'} ? $text{'delete_spamvirus'}
			       : $text{'delete_spam'});
local $spamrc = "$procmail_spam_dir/$_[0]->{'id'}";
&unlink_logged($spamrc);
local $spamdir = "$spam_config_dir/$_[0]->{'id'}";
&system_logged("rm -rf ".quotemeta($spamdir));
&clear_lookup_domain_cache($_[0]);
&save_domain_spam_autoclear($_[0], undef);
&$second_print($text{'setup_done'});
}

# check_spam_clash()
# No need to check for clashes ..
sub check_spam_clash
{
return 0;
}

# backup_spam(&domain, file)
# Saves the server's procmail and spamassassin configuration to a file.
# Also saves the auto-spam clearing settings.
sub backup_spam
{
&$first_print($text{'backup_spamcp'});
local $spamrc = "$procmail_spam_dir/$_[0]->{'id'}";
local $spamdir = "$spam_config_dir/$_[0]->{'id'}";
if (-r $spamrc) {
	&execute_command("cp ".quotemeta($spamrc)." ".
			       quotemeta($_[1]));
	&execute_command("cd ".quotemeta($spamdir)." && tar cf ".
			       quotemeta($_[1]."_cf")." . 2>/dev/null ");

	# Save spam clearing
	local $auto = &get_domain_spam_autoclear($_[0]);
	&write_file($_[1]."_auto", $auto || { });
	&$second_print($text{'setup_done'});
	return 1;
	}
else {
	&$second_print($text{'backup_nospam'});
	return 0;
	}
}

# restore_spam(&domain, file)
# Restores the domains procmail and spamassassin configuration files.
# Also restores auto-clearing setting, if in backup.
sub restore_spam
{
&$first_print($text{'restore_spamcp'});
local $spamrc = "$procmail_spam_dir/$_[0]->{'id'}";
local $spamdir = "$spam_config_dir/$_[0]->{'id'}";
&lock_file($spamrc);
&execute_command("cp ".quotemeta($_[1])." ".
		       quotemeta($spamrc));
&unlock_file($spamrc);
&lock_file("$spamdir/virtualmin.cf");
&execute_command("cd ".quotemeta($spamdir)." && tar xf ".
		       quotemeta($_[1]."_cf"));
&unlock_file("$spamdir/virtualmin.cf");

if (-r $_[1]."_auto") {
	# Replace auto-clearing setting
	&save_domain_spam_autoclear($_[0], undef);
	local %auto;
	&read_file($_[1]."_auto", \%auto);
	if (%auto) {
		&save_domain_spam_autoclear($_[0], \%auto);
		}
	}

&$second_print($text{'setup_done'});
return 1;
}

# sysinfo_spam()
# Returns the SpamAssassin version
sub sysinfo_spam
{
&require_spam();
local $vers = &spam::get_spamassassin_version();
return ( [ $text{'sysinfo_spam'}, $vers ] );
}

sub links_spam
{
local ($d) = @_;
if ($config{'avail_spam'}) {
	local %acl = &get_module_acl(undef, "spam");
	if ($acl{'file'}) {
		return ( { 'mod' => 'spam',
			   'desc' => $text{'links_spam'},
			   'page' => 'index.cgi',
			   'cat' => 'services',
			 });
		}
	}
return ( );
}

# find_spam_recipe(&recipes)
# Returns the one or two or four recipes used for spam filtering
sub find_spam_recipe
{
local $i;
for($i=0; $i<@{$_[0]}; $i++) {
	if ($_[0]->[$i]->{'action'} =~ /spamassassin|spamc/) {
		# Found spamassassin .. but is the next one using the header?
		local $r = $_[0]->[$i+1];
		local @rv = ( $_[0]->[$i], undef, undef, undef );
		if ($r->{'name'} eq 'SPAMMODE') {
			# There are SPAMMODE settings before and after the
			# delivery recipe
			$rv[1] = $r;
			$r = $_[0]->[$i+2];
			if ($r->{'name'} eq 'SPAMMODE') {
				# No delivery recipe?
				$rv[3] = $r;
				}
			elsif ($_[0]->[$i+3]->{'name'} eq 'SPAMMODE') {
				# SPAMMODE after delivery recipe
				$rv[3] = $_[0]->[$i+3];
				}
			}
		foreach my $c (@{$r->{'conds'}}) {
			if ($c->[1] =~ /X-Spam-Status/i) {
				$rv[2] = $r;
				last;
				}
			}
		return @rv;
		}
	}
return ( );
}

# get_domain_spam_delivery(&domain)
# Returns the delivery mode and dest for some domain. The modes can be :
# 0 - Throw away , 1 - File under home , 2 - Forward to email , 3 - Other file,
# 4 - Normal ~/mail/spam file , 5 - Deliver normally , 6 - ~/Maildir/.spam/ ,
# -1 - Broken!
sub get_domain_spam_delivery
{
local ($d) = @_;
&require_spam();
local $spamrc = "$procmail_spam_dir/$d->{'id'}";
local @recipes = &procmail::parse_procmail_file($spamrc);
local @spamrec = &find_spam_recipe(\@recipes);
if (!@spamrec) {
	return (-1);
	}
elsif (!$spamrec[2]) {
	return (5);
	}
elsif ($spamrec[2]->{'action'} eq '/dev/null') {
	return (0);
	}
elsif ($spamrec[2]->{'action'} =~ /^\$HOME\/mail\/spam$/) {
	return (4);
	}
elsif ($spamrec[2]->{'action'} =~ /^\$HOME\/Maildir\/\.spam\/$/) {
	return (6);
	}
elsif ($spamrec[2]->{'action'} =~ /^\$HOME\/(.*)$/) {
	return (1, $1);
	}
elsif ($spamrec[2]->{'action'} =~ /\@/) {
	return (2, $spamrec[2]->{'action'});
	}
else {
	return (3, $spamrec[2]->{'action'});
	}
}

# save_domain_spam_delivery(&domain, mode, dest)
# Updates the delivery method for spam for some domain
sub save_domain_spam_delivery
{
local ($d, $mode, $dest) = @_;
&require_spam();
local $spamrc = "$procmail_spam_dir/$d->{'id'}";
local @recipes = &procmail::parse_procmail_file($spamrc);
local @spamrec = &find_spam_recipe(\@recipes);
return 0 if (!@spamrec);
&lock_file($spamrc);
if ($mode == 5 && $spamrec[2]) {
	if ($spamrec[1]) {
		# Delete SPAMMODE settings and delivery recipe
		&procmail::delete_recipe($spamrec[3]);
		&procmail::delete_recipe($spamrec[2]);
		&procmail::delete_recipe($spamrec[1]);
		}
	else {
		# Delete just delivery recipe
		&procmail::delete_recipe($spamrec[2]);
		}
	}
elsif ($mode != 5) {
	# Create or update
	local $action = $mode == 0 ? "/dev/null" :
			$mode == 4 ? "\$HOME/mail/spam" :
			$mode == 6 ? "\$HOME/Maildir/.spam/" :
			$mode == 1 ? "\$HOME/$dest" :
				      $dest;
	local $type = $mode == 2 ? "!" : "";
	if ($spamrec[2]) {
		# Update recipe
		local $r = $spamrec[2];
		$r->{'action'} = $action;
		$r->{'type'} = $type;
		&procmail::modify_recipe($r);
		}
	else {
		# Create recipe
		local $r = { 'conds' => [ [ '', '^X-Spam-Status: Yes' ] ],
			     'action' => $action,
			     'type' => $type };
		local $spammode1 = { 'name' => 'SPAMMODE', 'value' => 1 };
		local $spammode0 = { 'name' => 'SPAMMODE', 'value' => 0 };
		local $idx = &indexof($spamrec[0], @recipes);
		if ($idx == @recipes-1) {
			# Add at end
			&procmail::create_recipe($spammode1, $spamrc);
			&procmail::create_recipe($r, $spamrc);
			&procmail::create_recipe($spammode0, $spamrc);
			}
		else {
			# Insert after spamassassin call
			&procmail::create_recipe_before($spammode1,
						$recipes[$idx+1], $spamrc);
			&procmail::create_recipe_before($r, $recipes[$idx+1],
							$spamrc);
			&procmail::create_recipe_before($spammode0,
						$recipes[$idx+1], $spamrc);
			}
		}
	}
&unlock_file($spamrc);
&clear_lookup_domain_cache($_[0]);
return 1;
}

# get_domain_spam_client(&domain)
# Returns the client program (spamassassin or spamc) used by some domain
sub get_domain_spam_client
{
local ($d) = @_;
&require_spam();
local $spamrc = "$procmail_spam_dir/$d->{'id'}";
local @recipes = &procmail::parse_procmail_file($spamrc);
foreach my $r (@recipes) {
	if ($r->{'action'} =~ /\/\S+\/(spamassassin|spamc)/) {
		return $1;
		}
	}
return undef;	# Cannot happen!
}

# save_domain_spam_client(&domain, spamassassin|spamc)
# Updates the procmail rule which calls spamassassin or spamc
sub save_domain_spam_client
{
local ($d, $client) = @_;
&require_spam();
local $spamrc = "$procmail_spam_dir/$d->{'id'}";
local @recipes = &procmail::parse_procmail_file($spamrc);
foreach my $r (@recipes) {
	if ($r->{'action'} =~ /\/\S+\/(spamassassin|spamc)/) {
		$r->{'action'} = &spamassassin_client_command($d, $client);
		&procmail::modify_recipe($r);
		}
	}
}

# get_global_spam_client()
# Returns the spam client that is supposed to be used by all domains. If this
# is spamc, also returns the spamd hostname and max message size
sub get_global_spam_client
{
local ($client, $host, $size);
if ($config{'spam_client_global'}) {
	# We know the global setting for sure
	$client = $config{'spam_client'};
	}
else {
	# Find the most used one for all domains
	local (%cmdcount, $maxcmd);
	foreach my $d (grep { $_->{'spam'} } &list_domains()) {
		local $cmd = &get_domain_spam_client($d);
		if ($cmd) {
			$cmdcount{$cmd}++;
			if (!$maxcmd || $cmdcount{$cmd} > $cmdcount{$maxcmd}) {
				$maxcmd = $cmd;
				}
			}
		}
	return $maxcmd || $config{'spam_client'};
	}
$host = $config{'spam_host'};
$size = $config{'spam_size'};
return wantarray ? ( $client, $host, $size ) : $client;
}

# save_global_spam_client(client, spamc-host, spamc-size)
# Updates all domains with a new SpamAssassin client program
sub save_global_spam_client
{
local ($client, $host, $size) = @_;
$config{'spam_client'} = $client;
$config{'spam_client_global'} = 1;
$config{'spam_host'} = $host;
$config{'spam_size'} = $size;
&save_module_config();
foreach my $d (grep { $_->{'spam'} } &list_domains()) {
	&save_domain_spam_client($d, $client);
	}
}

# update_spam_whitelist(&domain)
# Adds all mailboxes in this domain to the spamassassin whitelist in its
# configuration, and removes any whitelists that don't correspond to users.
sub update_spam_whitelist
{
local ($d) = @_;
return if (!$d->{'spam'} || !$d->{'spam_white'});
&require_spam();
local $spamfile = "$spam_config_dir/$d->{'id'}/virtualmin.cf";
local $conf = &spam::get_config($spamfile);
local @whites = &spam::find_value("whitelist_from", $conf);
local @oldwhites = @whites;
@whites = grep { !/\@$d->{'dom'}$/ } @whites;
foreach my $user (&list_domain_users($d, 0, 1, 1, 1)) {
	push(@whites, &remove_userdom($user->{'user'}, $d)."\@".$d->{'dom'});
	}
@whites = sort { $a cmp $b } @whites;
if (join(" ", @whites) ne join(" ", @oldwhites)) {
	# Need to update spamassassin config
	$spam::add_cf = $spamfile;
	&spam::save_directives($conf, "whitelist_from", \@whites, 1); 
	&flush_file_lines($spamfile);
	}
}

# show_template_spam(&template)
# Outputs HTML for editing spamassassin related template options
sub show_template_spam
{
local ($tmpl) = @_;

# Default spam clearing mode
local ($cmode, $cnum) = split(/\s+/, $tmpl->{'spamclear'});
local $cdays = $cmode eq 'days' ? $cnum : undef;
local $csize = $cmode eq 'size' ? $cnum : undef;
print &ui_table_row(&hlink($text{'tmpl_spamclear'}, 'template_spamclear'),
	    &ui_radio("spamclear", $cmode,
	        [ $tmpl->{'default'} ? ( )
				     : ( [ "", $text{'default'}."<br>" ] ),
		  [ "none", $text{'no'}."<br>" ],
		  [ "days", &text('spam_cleardays',
			     &ui_textbox("spamclear_days", $cdays, 5))."<br>" ],
		  [ "size", &text('spam_clearsize',
			     &ui_bytesbox("spamclear_size", $csize)) ],
		]));
}

# parse_template_spam(&tmpl)
# Updates spamassassin related template options from %in
sub parse_template_spam
{
local ($tmpl) = @_;

# Parse clearing option
if ($in{'spamclear'} eq '') {
	$tmpl->{'spamclear'} = '';
	}
elsif ($in{'spamclear'} eq 'none') {
	$tmpl->{'spamclear'} = 'none';
	}
elsif ($in{'spamclear'} eq 'days') {
	$in{'spamclear_days'} =~ /^\d+$/ && $in{'spamclear_days'} > 0 ||
		&error($text{'spam_edays'});
	$tmpl->{'spamclear'} = 'days '.$in{'spamclear_days'};
	}
elsif ($in{'spamclear'} eq 'size') {
	$in{'spamclear_size'} =~ /^\d+$/ && $in{'spamclear_size'} > 0 ||
		&error($text{'spam_esize'});
	$tmpl->{'spamclear'} = 'size '.($in{'spamclear_size'}*
					$in{'spamclear_size_units'});
	}
}

# clear_lookup_domain_cache(&domain, [&user])
# Removes entries from the lookup-domain cache for a user all users in a domain
sub clear_lookup_domain_cache
{
local ($d, $user) = @_;

# Open the cache DBM
local $cachefile = "$ENV{'WEBMIN_VAR'}/lookup-domain-cache";
local %cache;
eval "use SDBM_File";
dbmopen(%cache, $cachefile, 0700);
eval "\$cache{'1111111111'} = 1";
if ($@) {
	dbmclose(%cache);
	eval "use NDBM_File";
	dbmopen(%cache, $cachefile, 0700);
	}

if ($user) {
	# For just one user
	delete($cache{$user->{'user'}});
	}
else {
	# For all users in a domain
	foreach my $u (&list_domain_users($d, 0, 1, 1, 1)) {
		delete($cache{$u->{'user'}});
		}
	}
}

# get_domain_spam_autoclear(&domain)
# Returns an object containing spam clearing info for this domain, if defined
sub get_domain_spam_autoclear
{
local ($d) = @_;
local %spamclear;
&read_file_cached($spamclear_file, \%spamclear);
local $ds = $spamclear{$d->{'id'}};
return undef if (!$ds);
local %auto = map { split(/=/, $_, 2) } split(/\s+/, $ds);
return \%auto;
}

# save_domain_spam_autoclear(&domain, &autoclear)
# Saves the automatic spam clearing policy for a domain, and sets up the 
# cron job if needed
sub save_domain_spam_autoclear
{
local ($d, $auto) = @_;

# Update config file
local %spamclear;
&read_file_cached($spamclear_file, \%spamclear);
if ($auto) {
	$spamclear{$d->{'id'}} = join(" ", map { $_."=".$auto->{$_} }
					       keys %$auto);
	}
else {
	delete($spamclear{$d->{'id'}});
	}
&write_file($spamclear_file, \%spamclear);

# Fix cron job
&foreign_require("cron", "cron-lib.pl");
local ($job) = grep { $_->{'command'} eq $spamclear_cmd }
		    &cron::list_cron_jobs();
if ($job && !%spamclear) {
	# Disable job, as we don't need it
	&cron::delete_cron_job($job);
	}
elsif (!$job && %spamclear) {
	# Enable the job
	$job = { 'user' => 'root',
		 'command' => $spamclear_cmd,
		 'active' => 1,
		 'mins' => int(rand()*60),
		 'hours' => 0,
		 'days' => '*',
		 'months' => '*',
		 'weekdays' => '*' };
	&cron::create_cron_job($job);
	&cron::create_wrapper($spamclear_cmd, $module_name, "spamclear.pl");
	}
}

# create_spam_config_links(&domain)
# Creates links from the global spamasasassin config directory to the domain's
# spam directory.
sub create_spam_config_links
{
local ($d) = @_;
local $defdir;
&require_spam();
if (-d $spam::config{'local_cf'}) {
	$defdir = $spam::config{'local_cf'};
	}
elsif ($spam::config{'local_cf'} =~ /^(.*)\//) {
	$defdir = $1;
	}
local $spamdir = "$spam_config_dir/$d->{'id'}";
if ($defdir) {
	# Remove any old links
	opendir(DIR, $spamdir);
	foreach my $f (readdir(DIR)) {
		local $p = "$spamdir/$f";
		if ($f ne "." && $f ne "..") {
			local $lnk = readlink($p);
			if ($lnk && $lnk =~ /^\Q$defdir\/\E/ && !-e $lnk) {
				unlink($p);
				}
			}
		}
	closedir(DIR);

	# Create the new links
	opendir(DIR, $defdir);
	foreach my $f (readdir(DIR)) {
		if ($f ne "." && $f ne "..") {
			&symlink_logged("$defdir/$f", "$spamdir/$f");
			}
		}
	closedir(DIR);
	}
}

$done_feature_script{'spam'} = 1;

1;

