#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""guard.py: the Claude Code PreToolUse hook that enforces CLAUDE.md's hard rules on every tool call.

Exit 0 lets the call run; exit 2 blocks it and the message on stderr goes back to the agent.

1. Never allowed: Reset NVRAM (`nvram -c`), VBIOS flash tools, force-push, push to main/master, `reset --hard`,
   `clean -f`, `checkout .` / `restore .`, `branch -D`, bare `git stash` / `git stash pop` (the stash is shared by
   all worktrees).
2. Machine lock: writes to the EFI partition (also its scratch mount /private/tmp/efi), the system volume,
   /Library/Extensions, /Library/GPUBundles, /Library/LaunchDaemons, ~/gpu and ~/vermilion-rollback, and restarts,
   kmutil/bless/nvram writes and the like need the machine lock.
   One session holds it at a time (`.claude/hooks/machine-lock acquire "<reason>"`), so only one agent changes the
   machine (the one-EFI-change-per-boot rule needs a single owner). Text that only mentions those paths or tools
   (data heredoc bodies, quoted text given to read commands, commit messages) is not a change; see needs_lock.
3. Personal data: `git commit` is blocked when the staged diff contains a value from the private pattern list
   (~/.config/vermilion/private-patterns.txt, made by scripts/dev/private-patterns.sh: serials, MLB, ROM, UUID,
   MAC addresses, e-mail, the host and login names). The list stays outside the repo; matches are reported masked.

The git rules follow mattpocock/skills' git-guardrails-claude-code (MIT), changed so that pushing feature branches
stays allowed.
"""
import json
import os
import re
import subprocess
import sys
import time

LOCK = os.path.expanduser(os.environ.get('VERMILION_MACHINE_LOCK', '~/.vermilion/machine.lock'))
PATTERNS = os.path.expanduser(os.environ.get('VERMILION_PRIVATE_PATTERNS', '~/.config/vermilion/private-patterns.txt'))
STALE_S = 12 * 3600

# `git`, its global options (-C <dir>, -c <k=v>, --no-pager, ...), then the subcommand. Anchoring on the subcommand
# keeps a commit message such as "push to main" from matching the push rules.
GIT = r'\bgit(?:\s+(?:-[Cc]\s+\S+|--?[\w-]+(?:=\S+)?))*\s+'
FORBIDDEN = [
    (r'\bnvram\s+-\w*c\b', 'Reset NVRAM is never done: it removes phxfb-squat (CLAUDE.md, hard rules).'),
    (r'\b(amdvbflash|atiflash|atiwinflash|flashrom)\b', 'Never flash or write the VBIOS (CLAUDE.md rule 1).'),
    (GIT + r'push\b[^;&|]*(\s--force(-with-lease)?\b|\s-f\b|\s\+\S)', 'No force-push.'),
    (GIT + r'push\b[^;&|]*\s(\S+:)?(refs/heads/)?(main|master)(\s|$)', 'No direct push to main: open a PR and merge it.'),
    (GIT + r'reset\b[^;&|]*--hard\b', 'No `git reset --hard`: make a WIP commit or ask the owner.'),
    (GIT + r'clean\b[^;&|]*\s-\w*f', 'No `git clean -f`.'),
    (GIT + r'(checkout|restore)\b[^;&|]*\s(--\s+)?\.(\s|$)', 'No `git checkout .` / `git restore .`.'),
    (GIT + r'branch\b[^;&|]*\s-D\b', 'No `git branch -D`: use -d (merged branches only) or ask the owner.'),
    (GIT + r'stash(\s+pop\b|\s*($|[;&|]))', 'The stash is shared by every worktree: use `git stash push -u -m <tag>` and `git stash apply <sha>`, or a WIP commit.'),
]

PROTECTED_PATH = re.compile(
    r'/Volumes/(EFI|ESP|NO[ \\]+NAME)\b|(?<!build/efi)/EFI/(OC|BOOT)(/|\b)|(^|[\s"\'=])/System/|/Library/(Extensions|GPUBundles|LaunchDaemons|LaunchAgents|Video/Plug-Ins|PrivilegedHelperTools)\b'
    r'|(~|\$HOME|\$\{HOME\}|/Users/[^/\s]+)/gpu(/|\b)'
    # the rollback copies of replaced EFI binaries, and the scratch mount of the ESP
    r'|(~|\$HOME|\$\{HOME\}|/Users/[^/\s]+)/vermilion-rollback(/|\b)|(?<![\w.-])/(private/)?tmp/efi(/|\b)')
WRITE_VERB = re.compile(
    r'(^|[\s;&|("\'`])(cp|mv|rm|rsync|ditto|install|tee|dd|ln|chmod|chown|chflags|touch|mkdir|rmdir|unzip|tar|xattr|'
    r'sed\s+-i|perl\s+-p?i|plutil\s+-(replace|insert|remove|convert)|defaults\s+write|PlistBuddy)\b|>'
    r'|\bfind\b[^\n;&|]*\s-(delete|fprint\w*|fls)\b|\bcodesign\s+(-\w+\s+)*-\w*[sf]\b')
# Redirections that write nothing: they don't make a read of a protected path a write.
HARMLESS_REDIRECT = re.compile(r'\d*>>?\s*/dev/null\b|\d*>&\d|&>\s*/dev/null\b')
MACHINE_TOOL = re.compile(
    r'(^|[\s;&|(])(bless|kextload|kextunload|kextcache|shutdown|reboot|halt)\b'
    r'|\bcsrutil\s+(?!status\b|authenticated-root\s+status\b)'
    r'|\bkmutil\s+(install|create|load|unload|clear-staging|rebuild)\b'
    r'|\blaunchctl\s+(bootout|bootstrap|load|unload|kickstart|enable|disable)\s+(-\w+\s+)*system\b'
    r'|\bmount\s+-u?w\b|\bmount_msdos\b'
    r'|\bdiskutil\s+(mount|unmount|umount|erase\w*|apfs\s+(delete\w*|resize\w*|add\w*)|partitionDisk|resizeVolume|rename\w*)\b'
    r'|\bpmset\s+(restoredefaults|disablesleep|schedule)\b'
    r'|\bnvram\s+(-d\b|[^\s-][^\s]*=)'
    r'|\bsystemsetup\s+-set\w+')
# A lock command must be the whole Bash call, so nothing can run after a release or before an acquire unchecked.
LOCK_CMD = re.compile(r'^\s*(?:(?:sh|bash)\s+)?(?:\S*/)?machine-lock(?:\.sh)?\s+(acquire|steal|release)'
                      r'(?:\s+("[^"]*"|\'[^\']*\'|[^;&|<>`$()\n]*))?\s*$')
LOCK_MENTION = re.compile(r'(^|[;&|(]\s*)((sh|bash)\s+)?(\S*/)?machine-lock(\.sh)?\s+(acquire|steal|release)\b', re.M)


def block(msg):
    sys.stderr.write('BLOCKED by .claude/hooks/guard.py: ' + msg + '\n')
    sys.exit(2)


def read_lock():
    try:
        with open(LOCK) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_lock(data):
    os.makedirs(os.path.dirname(LOCK), mode=0o700, exist_ok=True)
    tmp = LOCK + '.tmp'
    with open(tmp, 'w') as f:
        json.dump(data, f)
    os.replace(tmp, LOCK)


def handle_lock_cmd(cmd, session):
    m = LOCK_CMD.match(cmd)
    if not m:
        block('run `machine-lock acquire|steal|release` as a Bash call of its own, with nothing before or after it.')
    op, rest = m.group(1), (m.group(2) or '').strip().strip('"\'')
    cur = read_lock()
    now = int(time.time())
    held_by_other = cur and cur.get('session') != session
    stale = cur and now - int(cur.get('since', 0)) > STALE_S
    if op == 'acquire':
        if held_by_other and not stale:
            block(f"the machine lock is held by another session since {time.ctime(cur.get('since', 0))} "
                  f"for: {cur.get('reason', '?')}. Wait, ask that thread, or use `steal` if it is stale.")
        write_lock({'session': session, 'reason': rest or 'unspecified', 'since': now})
    elif op == 'steal':
        if held_by_other and not stale:
            block('the lock is not stale (under 12 h old): ask the holding thread or the owner first.')
        write_lock({'session': session, 'reason': rest or 'stolen', 'since': now})
    elif op == 'release':
        if cur and cur.get('session') == session:
            os.remove(LOCK)


# Commands that only read. A mention of a protected path or of `shutdown` in their arguments (quoted or not) is not a
# change; only a redirect to a protected path makes them a write.
READ_CMDS = {'ls', 'cat', 'diff', 'cmp', 'grep', 'egrep', 'fgrep', 'rg', 'stat', 'file', 'head', 'tail', 'wc', 'echo',
             'printf', 'test', '[', 'xxd', 'hexdump', 'strings', 'shasum', 'md5', 'md5sum', 'sha256sum', 'du', 'df',
             'readlink', 'realpath', 'basename', 'dirname', 'which', 'type', 'sed', 'find', 'codesign', 'plutil',
             'lsof', 'true', ':'}
# Per command: arguments that turn the read command into a write or an exec.
READ_EXCEPTIONS = {
    'sed': re.compile(r'\s-\w*i'),
    'find': re.compile(r'\s-(delete|exec|execdir|ok|okdir|fprint\w*|fls)\b'),
    'plutil': re.compile(r'\s-(replace|insert|remove|convert|extract|create)\b'),
    # codesign reads only with -d/--display or -v/--verify
    'codesign': re.compile(r'^(?!.*\s(-\w*[dv]\b|--display|--verify))|\s-\w*[sf]\b'),
}
# Commands whose quoted arguments are text (commit and PR messages), not something that runs.
TEXT_CMDS = {'git', 'gh'}
# A heredoc fed to one of these is a script that runs, so its body is kept.
HEREDOC_RUNS = re.compile(r'(^|[\s;&|(])(sh|bash|zsh|ksh|dash|python\d*|perl|ruby|node|osascript|ssh|su|eval|source)\b')
HEREDOC = re.compile(r'<<(?!<)-?\s*([\'"]?)(\w+)\1')
WRAPPERS = re.compile(r'(\w+=\S*|sudo(\s+-\S+)*|time|command|nohup|env|exec)\s+')


def strip_heredocs(cmd):
    """Drop the bodies of heredocs that are data (cat, tee, grep ...); keep those fed to a shell or interpreter."""
    out, end = [], None
    for line in cmd.split('\n'):
        if end is not None:
            if line.strip() == end:
                end = None
            continue
        out.append(line)
        m = HEREDOC.search(line)
        if m and not HEREDOC_RUNS.search(line[:m.start()]):
            end = m.group(2)
    return '\n'.join(out)


def split_segments(cmd):
    """Split on ; & | && || and newlines outside quotes. Returns [(raw, skeleton, redirect_targets, substitution)]:
    the skeleton is the segment with quoted contents dropped, the targets are the words after an unquoted `>`, and
    `substitution` says the segment holds a `$(...)` or backtick, which can run anything."""
    segs, raw, skel, targets, sub = [], [], [], [], False
    i, n, quote = 0, len(cmd), None
    while i < n:
        c = cmd[i]
        if quote:
            raw.append(c)
            if c == '\\' and quote == '"' and i + 1 < n:
                raw.append(cmd[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
                skel.append(c)
            elif quote == '"' and (c == '`' or cmd.startswith('$(', i)):
                sub = True
            i += 1
            continue
        if c in '"\'':
            quote = c
            raw.append(c)
            skel.append(c)
        elif c == '\\' and i + 1 < n:
            raw.append(cmd[i:i + 2])
            skel.append(cmd[i:i + 2])
            i += 2
            continue
        elif c in ';\n|' or (c == '&' and cmd[i + 1:i + 2] != '>' and (i == 0 or cmd[i - 1] not in '<>')):
            segs.append((''.join(raw), ''.join(skel), targets, sub))
            raw, skel, targets, sub = [], [], [], False
        else:
            if c == '`' or cmd.startswith('$(', i):
                sub = True
            if c == '>' and cmd[i + 1:i + 2] != '&':
                j = i + 1
                while j < n and cmd[j] in '> \t':
                    j += 1
                m = re.match(r'"[^"]*"|\'[^\']*\'|[^\s;&|<>()]+', cmd[j:])
                if m:
                    targets.append(m.group(0).strip('"\''))
            raw.append(c)
            skel.append(c)
        i += 1
    segs.append((''.join(raw), ''.join(skel), targets, sub))
    return segs


def command_word(text):
    """The command a segment runs, as (basename, the text after it): leading `(`, `{`, `!` and the WRAPPERS
    (assignments, sudo, env, time ...) are skipped."""
    t = text.strip().lstrip('({!').strip()
    while True:
        m = WRAPPERS.match(t)
        if not m:
            break
        t = t[m.end():]
    m = re.match(r'[^\s;&|<>]+', t)
    return (os.path.basename(m.group(0)) if m else ''), (t[m.end():] if m else '')


def needs_lock(cmd):
    """A command needs the machine lock when it changes the machine. Heredoc bodies that are data, quoted text given
    to read commands (`grep "shutdown"`, `echo "rm ~/gpu/x"`) and commit messages only mention things, so they
    are ignored; a redirect to a protected path from a read command is still a write."""
    rest = []
    for raw, skel, targets, sub in split_segments(strip_heredocs(cmd)):
        word, args = command_word(skel)
        exc = READ_EXCEPTIONS.get(word)
        if word in READ_CMDS and not sub and not (exc and exc.search(' ' + args)):
            if any(PROTECTED_PATH.search(' ' + t) for t in targets):
                return True
            continue
        rest.append(skel if word in TEXT_CMDS and not sub else raw)
    return needs_lock_text('\n'.join(rest))


def needs_lock_text(cmd):
    """The text test on what needs_lock kept: a machine tool, or a protected path together with a write verb or a
    redirect anywhere in the text."""
    if MACHINE_TOOL.search(cmd):
        return True
    return bool(PROTECTED_PATH.search(cmd) and WRITE_VERB.search(HARMLESS_REDIRECT.sub(' ', cmd)))


def require_lock(session, what):
    cur = read_lock()
    if cur and cur.get('session') == session:
        return
    holder = f" (held by another session for: {cur.get('reason')})" if cur else ''
    block(f'{what} changes the machine and needs the machine lock{holder}. '
          'Run `.claude/hooks/machine-lock acquire "<reason>"` first, and release it when done.')


def mask(s):
    return s[:2] + '*' * max(0, len(s) - 4) + s[-2:] if len(s) > 4 else '****'


def check_private(cmd, cwd):
    if not re.search(GIT + r'commit\b', cmd):
        return
    if re.search(GIT + r'(add|rm|mv)\b', cmd):
        # The hook runs before the whole call, so files staged in the same call aren't in the diff yet.
        block('stage (`git add`, `git rm`, `git mv`) and commit in separate Bash calls, so the private-data check sees '
              'what the commit contains.')
    try:
        with open(PATTERNS) as f:
            pats = [l.strip() for l in f if len(l.strip()) >= 6 and not l.startswith('#')]
    except OSError:
        return
    if not pats:
        return
    # The index and every change to tracked files: covers `commit`, `commit -a` and `commit <path>` (a superset, so
    # an unstaged private value in a tracked file blocks the commit too).
    diff = ''
    for diff_args in (['diff', '--cached'], ['diff', 'HEAD']):
        try:
            diff += subprocess.run(['git', '-C', cwd] + diff_args + ['-U0', '--no-color'],
                                   capture_output=True, text=True, timeout=60).stdout
        except (OSError, subprocess.SubprocessError):
            pass
    added = '\n'.join(l[1:] for l in diff.splitlines() if l.startswith('+') and not l.startswith('+++')).lower()
    hits = sorted({p for p in pats if p.lower() in added})
    if hits:
        block('the staged changes contain private values (' + ', '.join(mask(h) for h in hits) +
              '): serials, MAC addresses, e-mail or the host name must never be committed (CLAUDE.md rules 4-5).')


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    tool = data.get('tool_name', '')
    inp = data.get('tool_input') or {}
    session = data.get('session_id') or 'unknown'
    cwd = data.get('cwd') or os.getcwd()
    if tool == 'Bash':
        cmd = inp.get('command', '')
        for pat, msg in FORBIDDEN:
            if re.search(pat, cmd):
                block(msg)
        if LOCK_MENTION.search(cmd):
            handle_lock_cmd(cmd, session)
            return
        if needs_lock(cmd):
            require_lock(session, 'this command')
        check_private(cmd, cwd)
    elif tool in ('Write', 'Edit', 'MultiEdit', 'NotebookEdit'):
        path = os.path.expanduser(inp.get('file_path') or inp.get('notebook_path') or '')
        if PROTECTED_PATH.search(' ' + path):
            require_lock(session, f'writing {path}')


if __name__ == '__main__':
    main()
