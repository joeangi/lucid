"""Sandboxed lifecycle regressions; never install host packages or touch its session."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import os, sys
from pathlib import Path
name=Path(sys.argv[0]).name
args=sys.argv[1:]
with open(os.environ['MOCK_LOG'], 'a') as f: f.write(name+' '+repr(args)+'\n')
if name=='apt-cache':
    for pkg in args[1:]:
        print(pkg+':\n  Candidate: '+os.environ.get('MOCK_QT','6.10.2'))
elif name=='dpkg-query':
    if os.environ.get('MOCK_APT_STATE'):
        packages=Path(os.environ['MOCK_APT_STATE']).read_text().splitlines()
        if args[-1] in packages: print('install ok installed',end='')
        elif 'Status-Abbrev' in ' '.join(args): print(''.join('ii '+p+'\n' for p in packages),end='')
        else: sys.exit(1)
    elif '-W' in args and len(args)>2:
        print('install ok installed', end='')
elif name=='Hyprland': print('Hyprland 0.55.2')
elif name=='gsettings':
    if os.environ.get('FAIL_GSETTINGS'): sys.exit(1)
    if args[0]=='get': print("'original'")
elif name=='systemctl':
    if 'is-enabled' in args: print('not-found'); sys.exit(1)
    if 'is-active' in args: print('inactive'); sys.exit(3)
elif name in ('busctl','flatpak','pgrep'): sys.exit(1)
elif name=='apt-mark':
    if args[0]=='showmanual': print('owned\nneeded\nunrelated')
elif name=='apt-get':
    if '-s' in args:
        if 'autoremove' in args: print('Remv owned [1.0]\nRemv unrelated [1.0]')
        elif 'purge' in args: print('Purg owned [1.0]')
    elif 'purge' in args:
        state=Path(os.environ['MOCK_APT_STATE'])
        state.write_text('\n'.join(p for p in state.read_text().splitlines() if p not in args))
elif name=='sudo':
    if os.environ.get('MOCK_ROOT_FILES'):
        import subprocess
        if args[0]=='apt-get':
            sys.exit(subprocess.call([str(Path(sys.argv[0]).parent/'apt-get'),*args[1:]]))
        if args[0] in ('cp','rm','install','rmdir') and all(a.startswith('-') or a.startswith(os.environ['MOCK_ROOT_FILES']+'/') for a in args[1:]):
            sys.exit(subprocess.call(['/usr/bin/'+args[0],*args[1:]]))
    if os.environ.get('MOCK_APT_STATE'):
        import subprocess
        clean=[a for a in args if a not in ('env','DEBIAN_FRONTEND=noninteractive')]
        if clean[0] in ('apt-get','apt-mark'):
            sys.exit(subprocess.call([str(Path(sys.argv[0]).parent/clean[0]),*clean[1:]]))
    print('Unexpected privileged command: '+repr(args), file=sys.stderr); sys.exit(99)
elif name=='qs': pass
'''

class Lifecycle(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='lucid-test-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.home = self.base / 'home'
        self.home.mkdir()
        self.bin = self.base / 'bin'; self.bin.mkdir()
        for name in ('apt-cache','dpkg-query','Hyprland','qs','matugen','awww',
                     'gsettings','systemctl','busctl','flatpak','pgrep','pkill',
                     'fc-cache','sudo','apt-get','apt-mark','dconf'):
            p=self.bin/name; p.write_text(MOCK); p.chmod(0o755)
        self.env=dict(os.environ, HOME=str(self.home), XDG_STATE_HOME=str(self.home/'.local/state'),
                      PATH=str(self.bin)+':/usr/bin:/bin', MOCK_LOG=str(self.base/'calls'))
        self.state=self.home/'.local/state/lucid'

    def run_script(self, script, *args, ok=True, input=''):
        proc=subprocess.run(['bash',str(REPO/script),*args],env=self.env,text=True,
                            input=input,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
        if ok: self.assertEqual(proc.returncode,0,proc.stdout)
        else: self.assertNotEqual(proc.returncode,0,proc.stdout)
        return proc

    def install(self):
        return self.run_script('support/ubuntu/install.sh','--minimal','--skip-deps','--no-theming',
                               '--no-look','--no-hypr','--no-wallpapers','--yes')

    def manifest(self,*lines):
        self.state.mkdir(parents=True,exist_ok=True)
        (self.state/'manifest').write_text('lucid-install\ttest\tstamp\n'+'\n'.join(lines)+'\n')

    def test_fresh_install_and_remove(self):
        self.install()
        self.assertTrue((self.home/'.config/quickshell/shell.qml').is_file())
        self.assertFalse((self.home/'.config/quickshell/.agents').exists())
        self.run_script('support/ubuntu/uninstall.sh','--yes','--no-archive')
        self.assertFalse((self.home/'.config/quickshell').exists())
        self.assertFalse(self.state.exists())
        self.assertEqual(list(self.home.iterdir()),[])

    def test_reinstall_restores_original_and_removes_backups(self):
        shell=self.home/'.config/quickshell'; shell.mkdir(parents=True)
        (shell/'personal.txt').write_text('my desktop')
        gtk=self.home/'.config/gtk-3.0'; gtk.mkdir()
        (gtk/'settings.ini').write_text('original GTK')
        self.install(); self.install()
        (gtk/'settings.ini').write_text('runtime mutation')
        self.run_script('support/ubuntu/uninstall.sh','--yes','--no-archive')
        self.assertEqual((shell/'personal.txt').read_text(),'my desktop')
        self.assertEqual((gtk/'settings.ini').read_text(),'original GTK')
        self.assertFalse((shell/'shell.qml').exists())
        self.assertEqual(list(shell.parent.glob('quickshell.backup-*')),[])

    def test_old_qt_fails_before_state(self):
        self.env['MOCK_QT']='6.4.2'
        out=self.run_script('support/ubuntu/install.sh','--check',ok=False)
        self.assertIn('needs Qt >= 6.6',out.stdout)
        self.assertFalse(self.state.exists())

    def test_check_is_read_only(self):
        self.run_script('support/ubuntu/install.sh','--check')
        self.assertEqual(list(self.home.iterdir()),[])

    def test_missing_original_preserves_recovery_and_target(self):
        target=self.home/'old'; target.write_text('current')
        copy=self.state/'originals/old'
        self.manifest(f'saved\t{target}\t{copy}')
        self.run_script('support/ubuntu/uninstall.sh','--yes','--no-archive',ok=False)
        self.assertEqual(target.read_text(),'current')
        self.assertTrue((self.state/'manifest').exists())
        copy.parent.mkdir(); copy.write_text('original')
        self.run_script('support/ubuntu/uninstall.sh','--yes','--no-archive')
        self.assertEqual(target.read_text(),'original')

    def test_moved_original_survives_retry_after_settings_failure(self):
        target=self.home/'config'; target.mkdir(); (target/'lucid').touch()
        backup=self.home/'backup'; backup.mkdir(); (backup/'original').write_text('old')
        self.manifest(f'moved\t{target}\t{backup}', 'gsetting\tschema\tkey\tvalue')
        self.env['FAIL_GSETTINGS']='1'
        self.run_script('support/ubuntu/uninstall.sh','--yes','--no-archive',ok=False)
        self.assertTrue((target/'original').exists())
        (target/'original').write_text('edited after partial uninstall')
        del self.env['FAIL_GSETTINGS']
        self.run_script('support/ubuntu/uninstall.sh','--yes','--no-archive')
        self.assertEqual((target/'original').read_text(),'edited after partial uninstall')
        self.assertFalse(backup.exists())

    def test_no_manifest_never_deletes_existing_shell(self):
        shell=self.home/'.config/quickshell'; shell.mkdir(parents=True)
        (shell/'mine').touch()
        self.run_script('support/ubuntu/uninstall.sh','--yes')
        self.assertTrue((shell/'mine').exists())

    def test_symlink_ancestor_cannot_escape_home(self):
        outside=self.base/'outside'; outside.mkdir(); (outside/'precious').touch()
        (self.home/'link').symlink_to(outside)
        self.manifest(f'created\t{self.home}/link/precious')
        self.run_script('support/ubuntu/uninstall.sh','--yes','--no-archive',ok=False)
        self.assertTrue((outside/'precious').exists())

    def test_archive_is_private_and_includes_current_files(self):
        target=self.home/'private'; target.write_text('secret')
        self.manifest(f'created\t{target}')
        self.run_script('support/ubuntu/uninstall.sh','--yes')
        archive=next(self.home.glob('lucid-uninstall-*.tar.gz'))
        self.assertEqual(archive.stat().st_mode & 0o777,0o600)
        import tarfile
        with tarfile.open(archive) as tar:
            self.assertIn(str(target).lstrip('/'),tar.getnames())

    def test_keep_packages_retains_recovery_and_skips_restored_files_on_retry(self):
        target=self.home/'new'; target.write_text('lucid')
        self.manifest(f'created\t{target}')
        self.run_script('support/ubuntu/uninstall.sh','--yes','--no-archive','--keep-packages')
        self.assertTrue(self.state.exists())
        target.write_text('mine now')
        self.run_script('support/ubuntu/uninstall.sh','--yes','--no-archive')
        self.assertEqual(target.read_text(),'mine now')

    def test_source_consent_is_not_implied_by_yes(self):
        # Source only definitions, avoiding preflight and all mutations.
        source='software_consent() {'+(REPO/'support/ubuntu/install.sh').read_text().split('software_consent() {',1)[1].split('# ------------------------------------------------------------- the manifest')[0]
        script='say() { echo \"$*\"; }; b=; dim=; ylw=; grn=; r=; SKIP_DEPS=0; ALLOW_THIRD_PARTY=0; SKIPPED_CAPABILITIES=();\n'+source+'\nASSUME_YES=1\nsoftware_consent test reason https://example.test /tmp optional \"test feature will not work\"\n'
        result=subprocess.run(['bash','-c',script,'test'],env=self.env,capture_output=True,text=True)
        self.assertNotEqual(result.returncode,0)
        self.assertIn('THIRD-PARTY DEPENDENCY  test',result.stdout)
        self.assertIn('[1] Install test',result.stdout)
        self.assertIn('[2] Skip',result.stdout)
        self.assertIn('If you skip      test feature will not work',result.stdout)
        self.assertIn('Choice: skip',result.stdout)

    def test_source_consent_accepts_numbered_install_choice(self):
        source='software_consent() {'+(REPO/'support/ubuntu/install.sh').read_text().split('software_consent() {',1)[1].split('# ------------------------------------------------------------- the manifest')[0]
        script='say() { echo \"$*\"; }; b=; dim=; ylw=; grn=; r=; SKIP_DEPS=0; ALLOW_THIRD_PARTY=0; ASSUME_YES=0; SKIPPED_CAPABILITIES=();\n'+source+'\nsoftware_consent test reason source dest optional impact\n'
        result=subprocess.run(['bash','-c',script,'test'],env=self.env,input='1\n',capture_output=True,text=True)
        self.assertEqual(result.returncode,0,result.stdout)
        self.assertIn('Choice: install',result.stdout)


    def test_runtime_assets_restore_only_owned_files(self):
        import sys
        from unittest.mock import patch
        sys.path.insert(0, str(REPO/'lucidprefs'))
        from install_journal import managed_paths
        self.manifest()
        wall=self.home/'Pictures/wallpapers/custom/same.jpg'
        wall.parent.mkdir(parents=True); wall.write_text('original')
        new=wall.parent/'new.jpg'
        with patch.dict(os.environ,self.env,clear=True):
            with managed_paths([wall,new]):
                wall.write_text('replacement'); new.write_text('imported')
        independent=wall.parent/'mine.jpg'; independent.write_text('user')
        cursor=self.home/'.local/share/icons/Independent-noshadow'
        cursor.mkdir(parents=True)
        self.run_script('support/ubuntu/uninstall.sh','--yes','--no-archive')
        self.assertEqual(wall.read_text(),'original')
        self.assertFalse(new.exists())
        self.assertEqual(independent.read_text(),'user')
        self.assertTrue(cursor.exists())

    def test_apt_cleanup_does_not_remove_unrelated_unused_packages(self):
        apt_state=self.base/'packages'; apt_state.write_text('owned\nneeded\nunrelated\n')
        self.env['MOCK_APT_STATE']=str(apt_state)
        self.manifest('apt\towned','apt\tneeded')
        out=self.run_script('support/ubuntu/uninstall.sh','--yes','--no-archive')
        self.assertEqual(apt_state.read_text().splitlines(),['needed','unrelated'])
        self.assertIn('keeping needed',out.stdout)
        # a shared dependency staying put is a finished uninstall, not a pending one
        self.assertFalse((self.state/'uninstall-started').exists())
        calls=(self.base/'calls').read_text()
        self.assertIn("apt-mark ['manual', 'needed']",calls)
        self.assertNotIn("apt-get ['autoremove",calls)

    def test_missing_moved_backup_never_deletes_current_config(self):
        target=self.home/'current'; target.write_text('keep')
        self.manifest(f'moved\t{target}\t{self.home}/missing')
        self.run_script('support/ubuntu/uninstall.sh','--yes','--no-archive',ok=False)
        self.assertEqual(target.read_text(),'keep')

    def test_archive_failure_stops_before_removal(self):
        target=self.home/'private'; target.write_text('secret')
        self.manifest(f'created\t{target}')
        gzip=self.bin/'gzip'; gzip.write_text('#!/bin/sh\nexit 1\n'); gzip.chmod(0o755)
        self.run_script('support/ubuntu/uninstall.sh','--yes',ok=False)
        self.assertEqual(target.read_text(),'secret')
        self.assertTrue(self.state.exists())

    def test_uninstall_pending_prevents_reinstall(self):
        self.manifest()
        (self.state/'uninstall-started').touch()
        self.run_script('support/ubuntu/install.sh','--minimal','--skip-deps','--yes',ok=False)
        self.assertFalse((self.home/'.config/quickshell').exists())

    def test_root_payload_backs_up_existing_file_before_replacement(self):
        self.state.mkdir(parents=True)
        target=self.base/'payload'; target.write_text('original')
        replacement=self.base/'new'; replacement.write_text('new')
        import shlex
        q=shlex.quote
        script=f'''set -euo pipefail
STATE_DIR={q(str(self.state))}
MANIFEST="$STATE_DIR/manifest"
ORIG_DIR="$STATE_DIR/originals"
warn() {{ echo "$*"; }}
source {q(str(REPO/'support/install-state.sh'))}
# after the source: it defines its own sudo wrapper
sudo() {{ "$@"; }}
install_root_file {q(str(replacement))} {q(str(target))}
install_root_file {q(str(replacement))} {q(str(target))}
'''
        subprocess.run(['bash','-c',script],check=True,env=self.env,capture_output=True)
        backup=self.state/'originals/root'/str(target).lstrip('/')
        self.assertEqual(backup.read_text(),'original')
        self.assertEqual(target.read_text(),'new')
        self.assertEqual((self.state/'manifest').read_text().count('root-saved'),1)

    def test_staged_build_records_cmake_created_symlink(self):
        self.state.mkdir(parents=True)
        stage=self.base/'stage'; binary=stage/'usr/local/bin'
        binary.mkdir(parents=True)
        (binary/'qs').symlink_to('/usr/local/bin/quickshell')
        import shlex
        q=shlex.quote
        # Privileged mutations are replaced with a no-op, including cp/install.
        script=f'''set -euo pipefail
STATE_DIR={q(str(self.state))}; MANIFEST="$STATE_DIR/manifest"; ORIG_DIR="$STATE_DIR/originals"
warn() {{ echo "$*"; }}
source {q(str(REPO/'support/install-state.sh'))}
# after the source: it defines its own sudo wrapper
sudo() {{ return 0; }}
install_staged {q(str(stage))}
'''
        subprocess.run(['bash','-c',script],check=True,env=self.env,capture_output=True)
        self.assertIn('/usr/local/bin/qs', (self.state/'manifest').read_text())


    def test_system_payload_and_repository_files_restore(self):
        import shutil
        checkout=self.base/'checkout'; checkout.mkdir()
        (checkout/'support').mkdir()
        (checkout/'support/ubuntu').mkdir()
        shutil.copy(REPO/'support/install-state.sh',checkout/'support/install-state.sh')
        system=self.base/'system'
        local=system/'usr/local'; apt=system/'etc/apt'
        script=(REPO/'support/ubuntu/uninstall.sh').read_text().replace('/usr/local',str(local)).replace('/etc/apt',str(apt))
        (checkout/'support/ubuntu/uninstall.sh').write_text(script)
        executable=local/'bin/quickshell'; executable.parent.mkdir(parents=True); executable.write_text('lucid')
        source=apt/'sources.list.d/lucid.sources'; source.parent.mkdir(parents=True); source.write_text('third party')
        original=self.state/'originals/root'/str(executable).lstrip('/')
        original.parent.mkdir(parents=True); original.write_text('original binary')
        self.manifest(f'root-saved\t{executable}\t{original}',f'root-created\t{source}')
        self.env['MOCK_ROOT_FILES']=str(self.base)
        self.run_script(checkout/'support/ubuntu/uninstall.sh','--yes','--no-archive')
        self.assertEqual(executable.read_text(),'original binary')
        self.assertFalse(source.exists())
        self.assertFalse(self.state.exists())
        self.assertIn("apt-get ['update', '-qq']",(self.base/'calls').read_text())

    def installer_functions(self, *names):
        """The named functions' source, lifted out of the Ubuntu installer."""
        text=(REPO/'support/ubuntu/install.sh').read_text()
        out=[]
        for name in names:
            start=text.index('\n'+name+'() {')+1
            out.append(text[start:text.index('\n}\n',start)+3])
        return ''.join(out)

    def test_root_commands_get_a_readable_umask(self):
        (self.bin/'sudo').write_text('#!/bin/sh\numask\n')
        script=f'umask 077\nsource {REPO/"support/install-state.sh"}\nsudo true\numask\n'
        out=subprocess.run(['bash','-c',script],env=self.env,capture_output=True,text=True,check=True).stdout.split()
        self.assertEqual(out,['0022','0077'])

    def test_ask_defaults_to_no_unless_told_otherwise(self):
        script='ASSUME_YES=0\n'+self.installer_functions('ask')+'ask q && echo yes || echo no\nask q y && echo yes || echo no\nask q && echo yes || echo no\n'
        out=subprocess.run(['bash','-c',script],env=self.env,input='\n\ny\n',capture_output=True,text=True).stdout.split()
        self.assertEqual(out,['no','yes','yes'])

    def test_apt_origins_trust_the_archive_and_consented_ppas_only(self):
        checks=(
            't() { trusted_origin "$1" && echo "$1:yes" || echo "$1:no"; }\n'
            'OS_ID=ubuntu\n'
            'ppa_origin ppa:cppiber/hyprland; echo; ppa_origin ppa:owner/ppa; echo\n'
            't Ubuntu; t UbuntuESMApps; t LP-PPA-cppiber-hyprland; t "Vendor Inc"; t unknown\n'
            'APPROVED_ORIGINS[LP-PPA-cppiber-hyprland]=1; t LP-PPA-cppiber-hyprland\n'
            'OS_ID=linuxmint; t linuxmint; t LP-PPA-other\n')
        script='declare -A APPROVED_ORIGINS=()\n'+self.installer_functions('ppa_origin','trusted_origin')+checks
        out=subprocess.run(['bash','-c',script],env=self.env,capture_output=True,text=True,check=True).stdout.splitlines()
        self.assertEqual(out,['LP-PPA-cppiber-hyprland','LP-PPA-owner','Ubuntu:yes','UbuntuESMApps:yes',
                              'LP-PPA-cppiber-hyprland:no','Vendor Inc:no','unknown:no',
                              'LP-PPA-cppiber-hyprland:yes','linuxmint:yes','LP-PPA-other:no'])

    def test_download_with_wrong_checksum_is_discarded(self):
        # a curl that "downloads" a fixed payload to wherever -o points
        (self.bin/'curl').write_text('#!/bin/sh\nwhile [ $# -gt 0 ]; do [ "$1" = -o ] && printf payload > "$2"; shift; done\n')
        (self.bin/'curl').chmod(0o755)
        import hashlib
        good=hashlib.sha256(b'payload').hexdigest()
        out=self.base/'file'
        script=('warn() { :; }\n'+self.installer_functions('fetch_verified')
                +f'fetch_verified https://example.test/x {"0"*64} {out} && echo kept || echo rejected\n'
                +f'[ -e {out} ] && echo present || echo absent\n'
                +f'fetch_verified https://example.test/x {good} {out} && echo kept || echo rejected\n')
        res=subprocess.run(['bash','-c',script],env=self.env,capture_output=True,text=True,check=True).stdout.split()
        self.assertEqual(res,['rejected','absent','kept'])

if __name__=='__main__': unittest.main()
