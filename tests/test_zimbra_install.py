"""Isolated regression tests: never run the installer or change host settings.

Run: python3 -m unittest discover -s tests -v
"""
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'zimbra-install.sh'
SOURCE = SCRIPT.read_text()


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='zimbra-test-')
        self.addCleanup(self.temporary.cleanup)
        self.tmp = Path(self.temporary.name)

    def bash(self, body, *args, ok=True):
        result = subprocess.run(
            ['bash', '-c', 'source "$1"\nshift\n' + body, 'test', str(SCRIPT), *map(str, args)],
            cwd=self.tmp, text=True, capture_output=True)
        if ok:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_bash_syntax_and_help(self):
        subprocess.run(['bash', '-n', str(SCRIPT)], check=True)
        result = subprocess.run(['bash', str(SCRIPT), '--help'], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('--csf-conf', result.stdout)
        self.assertIn('--ssh-port', result.stdout)
        self.assertNotIn('10.1.19', result.stdout)

    def test_os_mapping(self):
        function = re.search(r'^detect_ubuntu_version\(\) \{.*?^\}', SOURCE, re.M | re.S).group()
        fixture = self.tmp / 'os-release'
        function = function.replace('/etc/os-release', str(fixture))
        for version, codename in [('22.04', 'jammy'), ('24.04', 'noble')]:
            fixture.write_text(f'ID=ubuntu\nVERSION_ID="{version}"\n')
            result = self.bash(function + '\ndetect_ubuntu_version\nprintf "%s %s" "$UBUNTU_CODENAME" "$ZCS_VERSION"')
            self.assertEqual(result.stdout, f'{codename} 10.1.20')
        fixture.write_text('ID=ubuntu\nVERSION_ID="20.04"\n')
        self.assertNotEqual(self.bash(function + '\ndetect_ubuntu_version', ok=False).returncode, 0)

    def test_domain_validation(self):
        for domain in ['example.com', 'mail.example.com', 'example-domain.vn']:
            self.bash('is_valid_domain "$1"', domain)
        for domain in ['example.com.', 'example..com', '-example.com', 'example.com;id', 'a' * 64 + '.com']:
            self.assertNotEqual(self.bash('is_valid_domain "$1"', domain, ok=False).returncode, 0)

    def test_local_template_directory_survives_cd(self):
        result = self.bash('cd /\nprintf "%s" "$SCRIPT_DIR"')
        self.assertEqual(result.stdout, str(ROOT))

    def test_local_template_is_valid(self):
        self.bash('validate_csf_template "$1"', ROOT / 'csf.conf')

    def test_reject_empty_partial_duplicate_templates(self):
        fixture = self.tmp / 'csf.conf'
        for value in ['', 'TCP_IN = "22"\n', '<html>Error</html>\n', (ROOT/'csf.conf').read_text() + '\nTCP_IN = "7071"\n']:
            fixture.write_text(value)
            self.assertNotEqual(self.bash('validate_csf_template "$1"', fixture, ok=False).returncode, 0)

    def test_uploaded_config_replaces_default_and_opens_required_ports(self):
        template = ROOT / 'csf.conf'
        uploaded = self.tmp / 'uploaded.conf'
        content = template.read_text()
        tcp_in = re.search(r'^TCP_IN = ".*"$', content, re.M).group()
        tcp6_in = re.search(r'^TCP6_IN = ".*"$', content, re.M).group()
        custom1_log = re.search(r'^CUSTOM1_LOG = "(.*)"$', content, re.M).group(1)
        uploaded.write_text(
            content
            .replace(tcp_in, 'TCP_IN = "10050"')
            .replace(tcp6_in, 'TCP6_IN = "10050"')
            + '\n# Uploaded configuration marker\n'
        )
        output = self.tmp / 'result.conf'
        # Default: ADMIN_CIDR is empty -> 7071 is kept open for customer access
        self.bash('build_csf_config "$1" "$2" "25,443,2222,7071"', uploaded, output)
        values = dict(re.findall(r'^(\w+) = "(.*)"$', output.read_text(), re.M))
        self.assertEqual(values['TCP_IN'], '25,443,2222,7071,10050')
        self.assertEqual(values['TCP6_IN'], '25,443,2222,7071,10050')
        self.assertIn('# Uploaded configuration marker', output.read_text())
        self.assertEqual(values['TESTING'], '0')
        self.assertEqual(values['CUSTOM1_LOG'], custom1_log)

        # When ADMIN_CIDR is explicitly set -> 7071 is stripped from public TCP_IN
        restricted_output = self.tmp / 'restricted.conf'
        self.bash('ADMIN_CIDR="203.0.113.10"\nbuild_csf_config "$1" "$2" "25,443,2222"', output, restricted_output)
        restricted_values = dict(re.findall(r'^(\w+) = "(.*)"$', restricted_output.read_text(), re.M))
        self.assertNotIn('7071', restricted_values['TCP_IN'].split(','))
        self.assertNotIn('7071', restricted_values['TCP6_IN'].split(','))

    def test_failed_download_preserves_destination(self):
        target = self.tmp / 'csf.conf'
        target.write_text('original')
        result = self.bash('curl() { return 22; }\nfetch_verified https://invalid.test x "$1"', target, ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(target.read_text(), 'original')
        self.assertFalse(list(self.tmp.glob('*.part.*')))

    def test_checksum_rejects_tampering_and_symlinks(self):
        file = self.tmp / 'archive.tgz'
        file.write_bytes(b'checksum fixture')
        digest = hashlib.sha256(file.read_bytes()).hexdigest()
        body = """if ! command -v sha256sum >/dev/null; then sha256sum() { shasum -a 256 "$@"; }; fi
verify_sha256 "$1" "$2"
"""
        self.bash(body, file, digest)
        file.write_bytes(b'tampered')
        self.assertNotEqual(self.bash(body, file, digest, ok=False).returncode, 0)
        link = self.tmp / 'linked.tgz'
        link.symlink_to(file)
        self.assertNotEqual(self.bash(body, link, hashlib.sha256(file.read_bytes()).hexdigest(), ok=False).returncode, 0)

    def test_wrong_digest_preserves_destination(self):
        target = self.tmp / 'csf.conf'
        target.write_text('original')
        self.bash('''curl() {
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == --output ]]; then printf corrupted > "$2"; return; fi
        shift
    done
}
verify_sha256() { return 1; }
if fetch_verified https://invalid.test bad "$1"; then exit 99; fi
''', target)
        self.assertEqual(target.read_text(), 'original')

    def test_dns_does_not_shadow_entire_domain(self):
        dns = SOURCE.split('cat > /etc/dnsmasq.d/zimbra.conf <<EOF\n', 1)[1].split('\nEOF', 1)[0]
        self.assertNotIn('local=/', dns)
        self.assertIn('host-record=${FQDN},${LOCAL_IP}', dns)
        self.assertIn('mx-host=${DOMAIN},${FQDN},10', dns)
        self.assertLess(SOURCE.index('repair_bootstrap_dns\nsynchronize_system_clock'), SOURCE.index('dpkg --configure -a'))
        self.assertLess(SOURCE.index('dnsmasq --test'), SOURCE.index('cat > /etc/resolv.conf <<EOF'))

    def test_password_not_in_normal_summary(self):
        result = self.bash('''VERSION_ID=24.04; UBUNTU_CODENAME=noble; ZCS_VERSION=10.1.20; ZCS_BUILD=test
FQDN=mail.example.com; ADMIN_EMAIL=admin@example.com; ADMIN_PASS=unique-secret-test
DKIM_DNS_NAME=selector.example.com; DKIM_TXT_VALUE=public; STATUS=Running
print_install_summary''')
        self.assertNotIn('unique-secret-test', result.stdout)
        self.assertIn('/root/ZIMBRA-INSTALL-INFO.txt', result.stdout)

    def test_lfd_matches_only_structured_ip_and_failed_auth(self):
        module = self.tmp / 'zimbra-auth.pm'
        self.bash('write_zimbra_auth_module "$1"', module)
        subprocess.run(['perl', '-c', str(module)], check=True, capture_output=True)
        prefix = '2026-09-07 10:02:30,123 WARN [qtp123] '
        cases = [
            (prefix + '[name=user@example.com;ip=203.0.113.8;] security - cmd=Auth; error=authentication failed for user;', '203.0.113.8'),
            (prefix + '[ip=2001:db8::8;] security - cmd=Auth; error=authentication failed;', '2001:db8::8'),
            (prefix + '[ip=127.0.0.1;oip=203.0.113.8;] security - cmd=Auth; error=authentication failed;', ''),
            (prefix + '[ip=203.0.113.8;] security - cmd=Auth; status=success;', ''),
            (prefix + '[ip=999.999.0.1;] security - cmd=Auth; error=authentication failed;', ''),
            ('forged ip=203.0.113.8 error=authentication failed', ''),
            (prefix + '[name=user;ip=203.0.113.99;ip=203.0.113.8;] security - cmd=Auth; error=authentication failed;', ''),
            (prefix + '[name=ip=203.0.113.8;] security - cmd=Auth; error=authentication failed;', ''),
        ]
        for line, expected in cases:
            result = subprocess.run(['perl', '-e', 'require shift; my @r=ZimbraAuth::match(shift,shift); print $r[1] // "";', str(module), line, '/opt/zimbra/log/audit.log'], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected)

    def test_firewall_verification_detects_missing_rule(self):
        body = '''iptables() { printf '%s\\n' '-P INPUT DROP' '-A INPUT -p tcp -m tcp --dport 443 -j ACCEPT'; }
ip6tables() { iptables; }
verify_firewall_rules "$1"'''
        self.bash(body, '443')
        self.assertNotEqual(self.bash(body, '443,2222', ok=False).returncode, 0)

    def test_rollback_script_syntax(self):
        content = SOURCE.split("<<'ROLLBACK'\n", 1)[1].split('\nROLLBACK', 1)[0]
        script = self.tmp / 'rollback.sh'
        script.write_text(content)
        subprocess.run(['bash', '-n', str(script)], check=True)
        self.assertIn('iptables-restore -w 10', content)
        self.assertIn('ip6tables-restore -w 10', content)
        self.assertIn('flock 9', content)

    def test_rollback_restores_previous_configuration_and_rules(self):
        content = SOURCE.split("<<'ROLLBACK'\n", 1)[1].split('\nROLLBACK', 1)[0]
        fs = self.tmp / 'filesystem'
        for directory in ['etc/csf', 'etc/ufw', 'etc/default', 'usr/local/csf/bin']:
            (fs / directory).mkdir(parents=True, exist_ok=True)
        backup = self.tmp / 'backup'
        backup.mkdir()
        for folder in ['csf', 'ufw']:
            (backup / folder).mkdir()
            (backup / folder / 'config').write_text('previous')
            (fs / 'etc' / folder / 'config').write_text('new')
        (backup / 'ufw.default').write_text('previous-default')
        for service in ['csf', 'lfd', 'ufw', 'firewalld']:
            (backup / (service + '.state')).write_text('disabled')
        (backup / 'ufw.active').touch()
        (backup / 'ufw.enabled').touch()
        (backup / 'ipv4.rules').write_text('previous-v4')
        (backup / 'ipv6.rules').write_text('previous-v6')
        for path in ['/etc/csf', '/etc/ufw', '/etc/default/ufw', '/usr/local/csf/bin']:
            content = content.replace(path, str(fs) + path)
        mocks = """flock() { :; }
systemctl() { printf '%s\\n' "$*" >> events; }
iptables-restore() { cat > restored-v4; }
ip6tables-restore() { cat > restored-v6; }
"""
        script = backup / 'rollback.sh'
        script.write_text(content.replace('set -u', 'set -u\n' + mocks, 1))
        result = subprocess.run(['bash', str(script)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((fs / 'etc/csf/config').read_text(), 'previous')
        self.assertEqual((fs / 'etc/ufw/config').read_text(), 'previous')
        self.assertEqual((backup / 'restored-v4').read_text(), 'previous-v4')
        self.assertEqual((backup / 'restored-v6').read_text(), 'previous-v6')
        self.assertTrue((backup / 'rolled-back').exists())
        self.assertIn('restart ufw', (backup / 'events').read_text())
        # A completed rollback is idempotent and never changes a later config.
        (fs / 'etc/csf/config').write_text('after-rollback')
        subprocess.run(['bash', str(script)], check=True)
        self.assertEqual((fs / 'etc/csf/config').read_text(), 'after-rollback')

    def test_firewall_verification_skips_disabled_ipv6(self):
        self.bash("""IPV6_ENABLED=no
iptables() { printf '%s\\n' '-P INPUT DROP' '-A INPUT -p tcp --dport 443 -j ACCEPT'; }
ip6tables() { exit 99; }
verify_firewall_rules 443""")

    def test_no_untrusted_csf_cache(self):
        self.assertNotIn('"/tmp/csf.tgz"', SOURCE)
        self.assertNotIn('"./csf.tgz"', SOURCE)
        self.assertIn('rm -f /etc/csf/csf.conf', SOURCE)
        self.assertNotIn('SNMPNOTIFY="yes"', SOURCE)
        self.assertIn('zimbra-auto-admin', SOURCE)
        self.assertIn('25 80 443 465 587 993 995', SOURCE)

    def test_csf_conf_github_replacement(self):
        expected_url = 'https://raw.githubusercontent.com/phongdh262/tools/main/csf.conf'
        self.assertIn(f'CSF_TEMPLATE_URL="{expected_url}"', SOURCE)
        expected_hash = hashlib.sha256((ROOT / 'csf.conf').read_bytes()).hexdigest()
        self.assertIn(f'CSF_TEMPLATE_SHA256="{expected_hash}"', SOURCE)
        self.assertIn('rm -f /etc/csf/csf.conf', SOURCE)

    def test_configure_ssh_port_ubuntu22_and_24(self):
        fs = self.tmp / 'fs'
        (fs / 'etc/ssh').mkdir(parents=True, exist_ok=True)
        (fs / 'etc/systemd/system').mkdir(parents=True, exist_ok=True)
        (fs / 'usr/lib/systemd/system').mkdir(parents=True, exist_ok=True)
        (fs / 'usr/lib/systemd/system/ssh.socket').touch()
        func = re.search(r'^configure_ssh_port\(\) \{.*?^\}', SOURCE, re.M | re.S).group()
        func = func.replace('/etc/ssh', str(fs / 'etc/ssh'))
        func = func.replace('/etc/systemd', str(fs / 'etc/systemd'))
        func = func.replace('/usr/lib/systemd', str(fs / 'usr/lib/systemd'))
        func = func.replace('/lib/systemd', str(fs / 'usr/lib/systemd'))
        self.bash("""
systemctl() { return 0; }
sshd() { return 0; }
""" + func + "\nconfigure_ssh_port 2210")
        conf_dropin = fs / 'etc/ssh/sshd_config.d/50-zimbra-ssh-port.conf'
        self.assertTrue(conf_dropin.exists())
        self.assertIn('Port 2210', conf_dropin.read_text())
        socket_dropin = fs / 'etc/systemd/system/ssh.socket.d/listen.conf'
        self.assertTrue(socket_dropin.exists())
        self.assertIn('ListenStream=2210', socket_dropin.read_text())


if __name__ == '__main__':
    unittest.main()
