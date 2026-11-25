#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""guard_cases.py: the adversarial case table for .claude/hooks/guard.py (from the PR #32 review), plus the rows the
fail-closed fix added. Only command strings: nothing here is executed, each string goes to the guard as hook JSON.

    python3 -I tests/hooks/guard_cases.py [GUARD]           # one line per failing case, then a count; exit 1 on a fail
    python3 -I tests/hooks/guard_cases.py OLD_GUARD GUARD    # compare: tags each row ok / ok(fixed) / BYPASS / FALSEPOS
"""
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))

# (wanted exit code, command): 2 = blocked without the machine lock, 0 = allowed
CASES = [
    # --- kept blocks
    (2, 'git branch -D ownback/x'),
    (2, 'git -C /tmp/x branch -D ownback/x'),
    (2, 'echo hi; git branch -D x'),
    (2, 'git push --force fork ownback/x'),
    (2, 'git push fork +ownback/x'),
    (2, 'git push -f fork ownback/x'),
    (2, 'git push fork main'),
    (2, 'git push fork HEAD:main'),
    (2, 'git push fork HEAD:refs/heads/main'),
    (2, 'git -c a=b push fork main'),
    (2, 'ls && .claude/hooks/machine-lock acquire "x"'),
    (2, '.claude/hooks/machine-lock acquire "x"; cp a ~/gpu/b'),
    (2, '.claude/hooks/machine-lock release && sudo shutdown -r now'),
    (2, 'sudo nvram -c'),
    (2, 'git reset --hard HEAD~1'),
    (2, 'git stash'),
    (2, 'cat <<EOF\nx\nEOF\ngit push fork main'),
    (2, 'cat <<EOF\nx\nEOF\n.claude/hooks/machine-lock acquire "x"\ncp a ~/gpu/b'),
    # force spelled in a group of short options, or a quoted +refspec
    (2, 'git push -uf fork ownback/x'),
    (2, 'git push fork "+ownback/x"'),
    (2, 'git push --force-if-includes fork ownback/x'),
    (2, 'git branch -d -f ownback/x'),
    (2, 'git branch --delete --force ownback/x'),
    (2, 'git branch -Dq ownback/x'),
    (0, 'git push -u --follow-tags fork ownback/x'),
    (0, 'git branch -d ownback/x'),
    (0, 'git branch --format="%(refname)" -a'),
    # a newline after a lock command starts a second command
    (2, '.claude/hooks/machine-lock release\ncp a ~/gpu/b'),
    (2, '.claude/hooks/machine-lock acquire x\nsudo shutdown -r now'),
    (2, 'sh .claude/hooks/machine-lock\trelease\n\ncp a ~/gpu/b'),
    # a read command's output written to a file and then run (second review of #32)
    (2, 'echo "cp a ~/gpu/b" > /tmp/s; chmod +x /tmp/s; /tmp/s'),
    (2, "printf 'sudo shutdown -r now\\n' >> /tmp/s && chmod +x /tmp/s && /tmp/s"),
    (2, 'echo "rm -rf ~/vermilion-rollback" > /tmp/s\n./run /tmp/s'),
    # --- plain machine writes
    (2, 'cp a ~/gpu/b'),
    (2, 'sudo cp -R X.kext /Volumes/EFI/EFI/OC/Kexts/'),
    (2, 'cp a ~/vermilion-rollback/b'),
    (2, 'rm -rf /private/tmp/efi/EFI/OC'),
    (2, 'cp a /tmp/efi/EFI/OC/config.plist'),
    (2, 'sudo shutdown -r now'),
    (2, 'sudo reboot'),
    (2, 'sudo nvram phxfb-squat=1'),
    (2, 'sudo nvram -d phxfb-squat'),
    (2, 'sudo sysctl -w debug.phx.x=1'),
    (2, 'sudo sysctl debug.phx.x=1'),
    (2, 'sudo kmutil load -p /x.kext'),
    (2, 'sudo mount -uw /'),
    (2, 'sudo diskutil mount disk0s1'),
    (2, 'echo x > ~/gpu/f'),
    (2, 'echo x > "$HOME/gpu/f"'),
    (2, 'echo x >> /Volumes/EFI/EFI/OC/config.plist'),
    (2, 'cat a | sudo tee ~/gpu/f'),
    (2, 'sed -i "" s/a/b/ ~/gpu/f'),
    (2, 'find ~/gpu -name "*.bak" -delete'),
    (2, 'find ~/gpu -name x -exec rm {} +'),
    (2, 'plutil -replace X -string y /Volumes/EFI/EFI/OC/config.plist'),
    (2, 'codesign -fs - /Library/Extensions/X.kext'),
    (2, 'sh -c "rm ~/gpu/x"'),
    (2, 'bash <<EOF\nrm ~/gpu/x\nEOF'),
    (2, 'sudo sh <<EOF\nshutdown -r now\nEOF'),
    (2, 'echo "$(rm ~/gpu/x)"'),
    (2, 'echo `rm ~/gpu/x`'),
    (2, 'python3 - <<EOF\nimport os; os.remove(os.path.expanduser("~/gpu/x"))\nEOF'),
    # --- heredocs
    (2, 'cat <<EOF | sh\nrm -rf ~/gpu/x\nEOF'),
    (2, 'cat <<EOF | sudo sh\nshutdown -r now\nEOF'),
    (2, '/bin/sh <<EOF\nrm -rf ~/gpu/x\nEOF'),
    (2, '/bin/bash <<EOF\nshutdown -r now\nEOF'),
    (2, '/usr/bin/python3 - <<EOF\nimport os; os.system("cp a ~/gpu/b")\nEOF'),
    (2, 'sudo -s <<EOF\nrm -rf /Library/Extensions/X.kext\nEOF'),
    (2, 'xargs rm <<EOF\n/Users/x/gpu/f\nEOF'),
    (2, 'fish <<EOF\nrm ~/gpu/x\nEOF'),
    (2, 'awk -f - <<EOF\nBEGIN { system("cp a ~/gpu/b") }\nEOF'),
    (2, 'n=$((1<<4))\ncp a ~/gpu/b'),
    (2, 'echo "<<EOF"\ncp a ~/gpu/b'),
    (2, 'cat <<EOF-1\nhi\nEOF-1\ncp a ~/gpu/b'),
    (2, 'cat <<EOF-1\nhi\nEOF-1\nsudo shutdown -r now'),
    (2, 'cat > /tmp/s.sh <<EOF\nrm -rf ~/gpu/x\nEOF\nsh /tmp/s.sh'),
    (2, 'cat <<EOF > ~/gpu/f\nx\nEOF'),
    (2, 'sudo tee /Volumes/EFI/EFI/OC/config.plist <<EOF\nx\nEOF'),
    (2, 'bash -s <<EOF\nrm ~/gpu/x\nEOF'),
    (2, 'ssh host <<EOF\nreboot\nEOF'),
    (2, 'while read f; do rm "$f"; done <<EOF\n/Users/x/gpu/f\nEOF'),
    # --- read-command segments
    (2, 'echo "rm -rf ~/gpu/x" | sh'),
    (2, 'echo "shutdown -r now" | sudo sh'),
    (2, 'printf "nvram x=y\\n" | bash'),
    (2, 'ls ~/gpu/*.bak | xargs rm'),
    (2, 'find ~/gpu -name "*.bak" | xargs rm -f'),
    (2, 'find /Volumes/EFI/EFI/OC/Kexts -name "*.old" -print0 | xargs -0 rm -rf'),
    (2, 'cd ~/gpu && echo x > f'),
    (2, 'cd ~/gpu; cat a > phxboot-navi31.sh'),
    (2, 'cd /Volumes/EFI/EFI/OC && echo x > config.plist'),
    (2, 'd=~/gpu; echo x > $d/f'),
    (2, 'D=/Volumes/EFI/EFI/OC\ncat new.plist > $D/config.plist'),
    (2, 'echo x >| ~/gpu/f'),
    (2, 'echo x >& ~/gpu/f'),
    (2, 'cat x > >(tee ~/gpu/y)'),
    (2, 'cat <(rm -rf ~/gpu/x)'),
    (2, 'cat <(sudo shutdown -r now)'),
    (2, 'echo x > /Volumes/NO\\ NAME/EFI/OC/config.plist'),
    (2, 'echo x > "/Volumes/NO NAME/EFI/OC/config.plist"'),
    (2, "ls ~/gpu # don't worry\ncp x ~/gpu/y"),
    (2, "echo ok # it's fine\nsudo shutdown -r now"),
    (2, "echo $'\\'' ; rm -rf ~/gpu/x"),
    (2, '/tmp/evil/cat ~/gpu/x'),
    (2, 'find ~/gpu "-delete"'),
    (2, "sed -n 'w /Users/x/gpu/f' in"),
    (2, 'xxd -r in ~/gpu/f'),
    (2, 'echo x > ~/"gpu"/f'),
    (2, 'echo x > "$HOME"/gpu/f'),
    (2, 'cp a "$HOME"/gpu/f'),
    (2, 'sed -E -i "" s/a/b/ ~/gpu/f'),
    (2, 'codesign --force --sign - -v /Library/Extensions/X.kext'),
    (2, 'codesign --remove-signature /Library/Extensions/X.kext'),
    (2, 'echo x 2> ~/gpu/f'),
    (2, 'echo x &> ~/gpu/f'),
    (2, 'echo x>~/gpu/f'),
    (2, 'ls > ~/vermilion-rollback/list'),
    (2, 'grep x y > /private/tmp/efi/EFI/OC/z'),
    (2, 'if true; then echo x > ~/gpu/f; fi'),
    (2, 'for f in a; do echo $f > ~/gpu/$f; done'),
    (2, '{ echo x; } > ~/gpu/f'),
    (2, '( echo x ) > ~/gpu/f'),
    (2, 'ls; { cat a; cat b; } > ~/gpu/f'),
    (2, 'true && ( cat a ) > ~/gpu/f'),
    (2, 'echo x | cat > ~/gpu/f'),
    (2, 'ls() { rm -rf ~/gpu/x; }; ls'),
    (2, 'cat a \\\n > ~/gpu/f'),
    (2, 'test -f a && cp a ~/gpu/b'),
    (2, 'which reboot && reboot'),
    (2, 'echo x | sudo dd of=/Volumes/EFI/x'),
    (2, 'rg --pre "rm -rf /Users/x/gpu" x .'),
    (2, 'head -c 10 a | tee ~/gpu/f'),
    (2, 'echo x; shutdown -h now'),
    (2, 'true; (reboot)'),
    (2, 'echo a\\\n; reboot'),
    (2, 'printf x > $HOME/vermilion-rollback/f'),
    (2, 'diff a b > ${HOME}/gpu/f'),
    (2, 'echo x > /System/Library/x'),
    (2, 'echo x > /Library/LaunchDaemons/x.plist'),
    (2, 'cat a 1> ~/gpu/f 2>&1'),
    (2, 'cat a 2>/dev/null > ~/gpu/f'),
    (2, 'echo x >\t~/gpu/f'),
    (2, 'echo "a" "b" > ~/gpu/f'),
    (2, "echo 'a' > '/Users/x/gpu/f'"),
    (2, 'echo "a > b" > ~/gpu/f'),
    (2, 'echo \\" > ~/gpu/f'),
    (2, 'echo "\\"" > ~/gpu/f; echo "'),
    # --- git / gh with quoted arguments
    (2, 'git show HEAD:tools/phxctl/phxboot-navi31.sh > "$HOME/gpu/phxboot-navi31.sh"'),
    (2, 'git show HEAD:x > ~/gpu/x'),
    (2, 'git archive -o "/Volumes/EFI/x.tar" HEAD'),
    (2, 'gh release download v1 -D "/Volumes/EFI/EFI/OC"'),
    (2, 'git -C "$HOME/gpu" apply x.patch'),
    (2, 'git -c alias.x="!shutdown -r now" x'),
    (2, 'git diff > "/Users/x/vermilion-rollback/d.patch"'),
    (2, 'gh api x | tee "$HOME/gpu/f"'),
    (2, 'git worktree add "$HOME/gpu/w"'),
    # --- restarts and other tools
    (2, "osascript -e 'tell app \"System Events\" to restart'"),
    (2, 'sudo launchctl reboot system'),
    (2, 'sudo nvram -f vars.txt'),
    (2, 'sudo pmset -a hibernatemode 0'),
    (2, 'sudo efi/build.py install --esp /Volumes/EFI --stage everyday'),
    (2, 'sudo python3 efi/build.py install --esp /boot --stage everyday'),
    (2, 'sudo bless --mount /Volumes/x --setBoot'),
    # --- added with the fail-closed fix: more forms of the same gaps
    (2, 'sysctl -w kern.x=1'),
    (2, 'sudo sysctl -aw x=1'),
    (2, 'cp a "$HOME"/vermilion-rollback/f'),
    (2, 'sed -n -i.bak s/a/b/ ~/gpu/f'),
    (2, 'sed --in-place s/a/b/ ~/gpu/f'),
    (2, 'sed -f s.sed ~/gpu/f'),
    (2, 'efi/build.py install --esp /tmp/x --stage everyday'),
    (2, 'python3 efi/build.py install --esp "$HOME/esp" --stage test'),
    (2, "osascript -e 'tell application \"Finder\" to shut down'"),
    (2, 'osascript <<EOF\ntell app "System Events" to restart\nEOF'),
    (2, 'sudo nvram -xf vars.xml'),
    (2, 'sudo pmset sleep 0'),
    (2, 'pmset schedule wake "11/26/26 08:00:00"'),
    (2, 'codesign --sign - /Library/Extensions/X.kext'),
    (2, 'codesign -s - --force /Volumes/EFI/EFI/OC/Kexts/X.kext'),
    (2, 'git -C ~/gpu apply x.patch'),
    (2, 'git --git-dir=/Users/x/gpu/.git apply x.patch'),
    (2, 'git archive --output=/Volumes/EFI/x.tar HEAD'),
    (2, 'gh release download v1 --dir ~/gpu'),
    (2, 'gh run download 1 -D /private/tmp/efi/x'),
    (2, 'perl - <<EOF\nunlink "/Users/x/gpu/f";\nEOF'),
    (2, 'ruby <<EOF\nFile.delete("/Volumes/EFI/EFI/OC/x")\nEOF'),
    (2, 'node - <<EOF\nrequire("fs").unlinkSync(process.env.HOME + "/gpu/f")\nEOF'),
    (2, 'python3 <<EOF\nimport subprocess; subprocess.run(["sudo", "shutdown", "-r", "now"])\nEOF'),
    (2, 'python3 -c "import shutil; shutil.copy(\'a\', \'/Users/x/gpu/b\')"'),
    (2, "awk '{print > \"/Users/x/gpu/f\"}' in"),
    (2, '/sbin/reboot'),
    (2, 'sudo /sbin/shutdown -r now'),
    (2, 'echo x >! ~/gpu/f'),
    (2, 'echo x >>| ~/gpu/f'),
    (2, 'cat <<EOF >> ~/gpu/f\nx\nEOF'),
    (2, 'cat > /tmp/m <<EOF\nrm ~/gpu/x\nEOF\n/tmp/m'),
    (2, 'cat <<EOF\n$(rm ~/gpu/x)\nEOF'),
    (2, 'cat <<EOF\n`rm ~/gpu/x`\nEOF'),
    (2, 'cat <<EOF\nnever closed\ncp a ~/gpu/b'),
    (2, 'ls ~/gpu | while read f; do rm "$f"; done'),
    (2, 'ls ~/gpu/* | cpio -pdm /tmp/x && rm -rf ~/gpu/x'),
    (2, 'echo ~/gpu/x | sudo xargs rm'),
    (2, 'export PATH=/tmp/evil:$PATH; cat ~/gpu/x'),
    (2, 'PATH=/tmp/evil cat ~/gpu/x'),
    (2, 'X=1 cp a ~/gpu/b'),
    (2, 'nice -n 5 sh -c "rm ~/gpu/x"'),
    (2, 'timeout 5 bash -c "shutdown -r now"'),
    (2, 'sudo -i rm ~/gpu/x'),
    (2, 'sudo -u root sh -c "cp a /Volumes/EFI/x"'),
    (2, 'su root -c "rm ~/gpu/x"'),
    (2, 'echo ${HOME}/x; cp a ${X}/gpu/b; cp a ~/gpu/c'),
    (2, 'echo x > ~/gpu/*.sh'),
    (2, 'echo x > ~root/gpu/f'),
    (2, 'echo x > $TMP; cp a ~/gpu/b'),
    (2, 'ls ~/gpu/*(e:"rm $REPLY":)'),
    (2, 'cp a =(rm ~/gpu/x)'),
    (2, 'find ~/gpu -name x -execdir rm {} +'),
    (2, 'find ~/gpu -fprint ~/gpu/list'),
    (2, 'plutil -convert binary1 /Volumes/EFI/EFI/OC/config.plist'),
    (2, 'plutil -extract a xml1 -o ~/gpu/x in.plist'),
    (2, 'rg --pre=./p x ~/gpu'),
    (2, 'xxd in.bin ~/gpu/out'),
    (2, '/opt/x/grep -c x ~/gpu/f'),
    (2, 'echo x | tee -a /etc/sysctl.conf'),
    (2, 'git -C ~/gpu checkout -- phxboot-navi31.sh'),
    (2, 'git commit -m x; cp a ~/gpu/b'),
    (2, 'git commit -m "x $(rm ~/gpu/x)"'),
    (2, 'gh pr create -t x -b y > ~/gpu/f'),
    (2, 'git log > ~/vermilion-rollback/log'),
    (2, 'sudo -E cp a ~/gpu/b'),
    (2, 'env -S "rm ~/gpu/x"'),
    (2, 'env cp a ~/gpu/b'),
    (2, 'eval "rm ~/gpu/x"'),
    (2, 'cat a <> ~/gpu/f'),
    (2, '> ~/gpu/f'),
    (2, 'echo x 1>~/gpu/f'),
    (2, 'echo "a\\\nb" > ~/gpu/f'),
    (2, 'cp a ~/{gpu,x}/b'),
    # kept false positives (fail closed): inline interpreter code that names a protected path, find -exec on one,
    # a heredoc written to a file and then any other command
    (2, "python3 - <<'EOF'\nprint(open('/Users/x/gpu/phxboot-navi31.sh').read())\nEOF"),
    (2, "find ~/gpu -name '*.sh' -exec grep -l phx {} +"),
    (2, "cat > /tmp/msg <<'EOF'\ndocs: cp a ~/gpu/b\nEOF\ngit commit -F /tmp/msg"),
    # --- allowed as before: not provably read-only, but the whole-text test finds no write (a script's file isn't read)
    (0, 'cat <<EOF'),
    (0, 'source /tmp/x.sh ~/gpu'),
    (0, 'cd ~/gpu && ls'),
    (0, 'grep -rn bash ~/gpu'),
    # --- allowed: provably read-only (no lock held)
    (0, 'ls ~/gpu'),
    (0, 'cat /Volumes/EFI/EFI/OC/config.plist | grep -c Kext'),
    (0, 'grep -rn "shutdown" tools/'),
    (0, 'echo "rm ~/gpu/x"'),
    (0, 'echo "rm ~/gpu/x" > /tmp/note; cat /tmp/note'),
    (0, 'grep -n shutdown tools/x.sh > /tmp/hits; wc -l /tmp/hits'),
    (0, 'git commit -m "guard: cp to ~/gpu needs the lock; shutdown too"'),
    (0, 'cat <<EOF\ncp a ~/gpu/b\nEOF'),
    (0, 'diff ~/gpu/a tools/phxctl/a > /dev/null 2>&1'),
    (0, 'nvram -p | grep phx'),
    (0, 'sysctl debug.phx'),
    (0, 'codesign -dv /Library/Extensions/X.kext'),
    (0, 'find ~/gpu -name "*.sh"'),
    (0, 'ls ~/vermilion-rollback'),
    (0, 'sysctl -n hw.ncpu'),
    (0, 'pmset -g batt'),
    (0, 'cmp ~/gpu/phxboot-navi31.sh tools/phxctl/phxboot-navi31.sh'),
    (0, 'stat -f %m ~/gpu/phxboot-navi31.sh'),
    (0, 'sed -n 1,20p ~/gpu/phxboot-navi31.sh'),
    (0, "sed -n -e '/phx/p' /Volumes/EFI/EFI/OC/config.plist"),
    (0, 'codesign -d --entitlements - /Library/Extensions/X.kext'),
    (0, 'codesign --verify --deep --strict /Library/Extensions/X.kext'),
    (0, 'plutil -p /Volumes/EFI/EFI/OC/config.plist'),
    (0, 'plutil -lint /Volumes/EFI/EFI/OC/config.plist'),
    (0, 'sudo ls -la /Volumes/EFI/EFI/OC/Kexts'),
    (0, 'sudo cat /Library/LaunchDaemons/x.plist'),
    (0, 'xxd -l 64 /Volumes/EFI/EFI/OC/OpenCore.efi'),
    (0, 'cat /etc/hosts'),
    (0, 'git commit -F - <<EOF\nguard: rm ~/gpu/x and sudo shutdown -r now need the lock\nEOF'),
    (0, "git commit -F - <<'EOF'\nuse `cp a ~/gpu/b` with the lock; $(not run)\nEOF"),
    (0, 'gh pr create --title "guard: ~/gpu writes" --body "cp a ~/gpu/b; sudo shutdown -r now"'),
    (0, 'gh pr comment 32 -b "reboot after cp to /Volumes/EFI"'),
    (0, 'git -C ~/gpu status'),
    (0, 'git diff --no-index ~/gpu/phxboot-navi31.sh tools/phxctl/phxboot-navi31.sh'),
    (0, 'git log --oneline -5 | cat'),
    (0, "cat > notes.md <<'EOF'\nRun sudo shutdown -r now, then cp ~/gpu/a /Volumes/EFI/EFI/OC\nEOF"),
    (0, "grep -n 'shutdown -r' ~/gpu/phxboot-navi31.sh | head -3"),
    (0, 'echo "after this: sudo reboot"'),
    (0, 'ls tools/linux/reboot_to_linux.sh'),
    (0, 'cp a /tmp/b'),
    (0, 'echo x > /tmp/f && cat /tmp/f'),
    (0, 'diskutil list; csrutil status'),
    (0, "git commit -m 'costs $5: cp a ~/gpu/b'"),
]
WRITES = [
    (2, '/Users/x/gpu/f'), (2, '/Users/x/vermilion-rollback/f'), (2, '/private/tmp/efi/EFI/OC/config.plist'),
    (2, '/tmp/efi/x'), (2, '/Volumes/EFI/EFI/OC/config.plist'), (2, '/Library/Extensions/x'),
    (2, '~/gpu/f'), (2, '/System/Library/x'), (0, '/tmp/x'), (0, '/private/tmp/claude-501/efi-notes.md'),
    (2, '/Users/x/Library/LaunchAgents/a.plist'), (2, '/etc/sysctl.conf'),
]


def run(guard, env, tmp, value, tool='Bash'):
    inp = {'command': value} if tool == 'Bash' else {'file_path': value, 'content': 'x'}
    p = subprocess.run([sys.executable, '-I', guard], capture_output=True, text=True, env=env, input=json.dumps(
        {'session_id': 'adv', 'tool_name': tool, 'cwd': tmp, 'tool_input': inp}))
    return p.returncode


def main():
    guards = sys.argv[1:] or [os.path.join(HERE, '..', '..', '.claude', 'hooks', 'guard.py')]
    tmp = tempfile.mkdtemp()
    env = dict(os.environ, VERMILION_MACHINE_LOCK=tmp + '/lock', VERMILION_PRIVATE_PATTERNS=tmp + '/pats')
    rows = [(w, c, 'Bash') for w, c in CASES] + [(w, p, 'Write') for w, p in WRITES]
    fails = 0
    for want, value, tool in rows:
        got = [run(g, env, tmp, value, tool) for g in guards]
        new = got[-1]
        fails += new != want
        label = ('Write ' if tool == 'Write' else '') + repr(value)
        if len(guards) == 1:
            if new != want:
                print(f'FAIL (got {new}, wanted {want}): {label}')
            continue
        old = got[0]
        tag = 'ok' if new == want else ('BYPASS' if want == 2 else 'FALSEPOS')
        if tag != 'ok':
            tag += '(regression)' if old == want else '(pre-existing)'
        elif old != want:
            tag = 'ok(fixed)'
        print(f'{tag:24} old={old} new={new} {label}')
    blocked = sum(1 for w, _, _ in rows if w == 2)
    print(f'guard_cases: {len(rows) - fails} passed, {fails} failed ({blocked} must-block rows, '
          f'{len(rows) - blocked} must-allow rows)')
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
