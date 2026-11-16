#!/usr/bin/env bash
# Tests for scripts/lib/upsert_pr_comment.js (#41).
#
# Dependency-free: requires bash and node (no npm packages). A fake `github`
# client records every create/update/delete, so no network or token is used.
#
# Usage: bash scripts/tests/test_upsert_pr_comment.sh
set -uo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"

# The workflow must post through the module, not inline per-run comments.
WF_FAIL=0
for kind in dbt-data-diff dbt-schema-diff; do
  if ! grep -q "kind: '$kind'" "$WORKFLOW"; then
    echo "    FAIL - ci.yml does not post $kind through upsert_pr_comment.js"; WF_FAIL=1
  fi
done
if grep -q "createComment" "$WORKFLOW"; then
  echo "    FAIL - ci.yml still calls createComment directly"; WF_FAIL=1
fi
# Two close pushes must not both find no comment and both create one: runs for a
# PR queue behind each other (not cancelled -- that could orphan the BigQuery dataset).
if ! grep -q "^concurrency:" "$WORKFLOW" \
  || ! grep -q "group:.*github.event.pull_request.number || github.ref" "$WORKFLOW" \
  || ! grep -q "cancel-in-progress: false" "$WORKFLOW"; then
  echo "    FAIL - ci.yml lacks a per-PR concurrency group with cancel-in-progress: false"; WF_FAIL=1
fi

node - "$REPO_ROOT/scripts/lib/upsert_pr_comment.js" <<'JS'
const upsert = require(process.argv[2]);
let pass = 0, fail = 0;
const ok = (cond, msg) => { if (cond) { pass++; console.log(`    ok   - ${msg}`); } else { fail++; console.log(`    FAIL - ${msg}`); } };

const bot = { type: 'Bot', login: 'github-actions[bot]' };
const human = { type: 'User', login: 'someone' };

function fakeGithub(comments) {
  const calls = [];
  const listComments = () => {};
  return {
    calls,
    paginate: async (fn, args) => { ok(fn === listComments && args.issue_number === 7, 'lists comments on the PR'); return comments; },
    rest: { issues: {
      listComments,
      createComment: async (a) => calls.push(['create', a]),
      updateComment: async (a) => calls.push(['update', a]),
      deleteComment: async (a) => calls.push(['delete', a]),
    } },
  };
}
const context = (runNumber, runId) => ({ repo: { owner: 'o', repo: 'r' }, issue: { number: 7 }, runNumber, runId });

(async () => {
  console.log('test_upsert_pr_comment.sh');

  console.log('  scenario 1: no existing comment -> create one with the stable marker');
  let gh = fakeGithub([{ id: 1, user: human, body: 'LGTM' }]);
  await upsert({ github: gh, context: context(1, 100), kind: 'dbt-data-diff', body: '# Diff A' });
  ok(gh.calls.length === 1 && gh.calls[0][0] === 'create', 'one create, nothing else');
  ok(gh.calls[0][1].body.startsWith('<!-- dbt-data-diff -->\n# Diff A'), 'body starts with stable marker');
  ok(!gh.calls[0][1].body.includes('Previous run'), 'no previous-run block on first post');

  console.log('  scenario 2: re-run -> update in place, previous run kept collapsed');
  const first = '<!-- dbt-data-diff -->\n# Diff A\n\n---\n*Run #1 (100)*';
  gh = fakeGithub([{ id: 5, user: bot, body: first }]);
  await upsert({ github: gh, context: context(2, 200), kind: 'dbt-data-diff', body: '# Diff B' });
  ok(gh.calls.length === 1 && gh.calls[0][0] === 'update' && gh.calls[0][1].comment_id === 5, 'updates comment 5, no create');
  const b2 = gh.calls[0][1].body;
  ok(b2.startsWith('<!-- dbt-data-diff -->\n# Diff B'), 'current run on top');
  ok(b2.includes('<details><summary>Previous run</summary>') && b2.includes('# Diff A') && b2.includes('*Run #1 (100)*'), 'previous run kept in <details>');

  console.log('  scenario 3: history stays one run deep');
  gh = fakeGithub([{ id: 5, user: bot, body: b2 }]);
  await upsert({ github: gh, context: context(3, 300), kind: 'dbt-data-diff', body: '# Diff C' });
  const b3 = gh.calls[0][1].body;
  ok(b3.includes('# Diff B') && !b3.includes('# Diff A'), 'keeps run 2, drops run 1');
  ok((b3.match(/Previous run/g) || []).length === 1, 'exactly one previous-run block');

  console.log('  scenario 4: legacy per-run comments are collapsed into one');
  gh = fakeGithub([
    { id: 10, user: bot, body: '<!-- dbt-data-diff-111 -->\n# old 1' },
    { id: 11, user: human, body: '<!-- dbt-data-diff -->\nquoted by a human' },
    { id: 12, user: bot, body: '<!-- dbt-data-diff-222 -->\n# old 2' },
    { id: 13, user: bot, body: '<!-- dbt-schema-diff-222 -->\n# schema' },
  ]);
  await upsert({ github: gh, context: context(4, 400), kind: 'dbt-data-diff', body: '# Diff D' });
  const kinds = gh.calls.map((c) => `${c[0]}:${c[1].comment_id || ''}`);
  ok(JSON.stringify(kinds) === JSON.stringify(['update:12', 'delete:10']), `updates newest (12), deletes 10 (got ${kinds})`);
  ok(gh.calls[0][1].body.includes('# old 2'), 'legacy body becomes the previous run');
  ok(!kinds.includes('delete:11') && !kinds.includes('delete:13'), "never touches a human's comment or another kind");

  console.log('  scenario 5: kinds are independent');
  gh = fakeGithub([{ id: 20, user: bot, body: first }]);
  await upsert({ github: gh, context: context(5, 500), kind: 'dbt-schema-diff', body: '# Schema' });
  ok(gh.calls.length === 1 && gh.calls[0][0] === 'create' && gh.calls[0][1].body.startsWith('<!-- dbt-schema-diff -->'), 'schema diff creates its own comment');

  console.log('  scenario 6: stays under the GitHub body limit');
  const big = 'x'.repeat(40000);
  gh = fakeGithub([{ id: 30, user: bot, body: `<!-- dbt-data-diff -->\n${big}` }]);
  await upsert({ github: gh, context: context(6, 600), kind: 'dbt-data-diff', body: big });
  ok(gh.calls[0][1].body.length <= 65536 && !gh.calls[0][1].body.includes('Previous run'), 'previous run dropped when it would not fit');
  gh = fakeGithub([]);
  await upsert({ github: gh, context: context(7, 700), kind: 'dbt-data-diff', body: 'y'.repeat(70000) });
  ok(gh.calls[0][1].body.length <= 65536 && gh.calls[0][1].body.endsWith('*(truncated to fit GitHub)*'), 'oversized current body truncated');

  console.log('');
  console.log(`passed: ${pass}  failed: ${fail}`);
  process.exit(fail === 0 ? 0 : 1);
})();
JS
NODE_RC=$?
[[ $WF_FAIL -eq 0 && $NODE_RC -eq 0 ]]
