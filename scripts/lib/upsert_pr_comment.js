// Keep one CI comment per kind on a PR, updated in place (#41).
//
// Each kind ("dbt-data-diff", "dbt-schema-diff") owns one comment, found by a
// stable marker `<!-- <kind> -->`. A re-run updates it instead of posting a new
// one, and the previous run's summary is kept below in a collapsed <details>, so
// re-runs neither pile up nor lose the last result. Older comments of the same
// kind by the same bot -- including the per-run `<!-- <kind>-<runId> -->` ones
// earlier versions posted -- are deleted, newest kept.
//
// Called from actions/github-script:
//   const upsert = require(`${process.env.GITHUB_WORKSPACE}/scripts/lib/upsert_pr_comment.js`);
//   await upsert({ github, context, kind: 'dbt-data-diff', body });

// GitHub rejects comment bodies over 65536 characters.
const MAX_BODY = 65000;
const PREVIOUS_OPEN = '<details><summary>Previous run</summary>';

function marker(kind) {
  return `<!-- ${kind} -->`;
}

// Matches the stable marker and the old per-run `<!-- kind-<runId> -->` form.
function isOurs(comment, kind) {
  const body = comment.body || '';
  const isBot = comment.user && comment.user.type === 'Bot';
  return isBot && (body.startsWith(marker(kind)) || new RegExp(`^<!-- ${kind}-\\d+ -->`).test(body));
}

// The current-run part of an existing comment: drop the marker line and any
// "Previous run" block it already carries, so history stays one run deep.
function currentPart(body) {
  const withoutMarker = body.replace(/^<!-- [^>]* -->\n?/, '');
  const cut = withoutMarker.indexOf(PREVIOUS_OPEN);
  return (cut >= 0 ? withoutMarker.slice(0, cut) : withoutMarker).trim();
}

function render(kind, body, runNumber, runId, previous) {
  let out = `${marker(kind)}\n${body.trim()}\n\n---\n*Run #${runNumber} (${runId})*`;
  if (previous) {
    const block = `\n\n${PREVIOUS_OPEN}\n\n${previous}\n\n</details>`;
    if (out.length + block.length <= MAX_BODY) {
      out += block;
    }
  }
  if (out.length > MAX_BODY) {
    out = out.slice(0, MAX_BODY - 40) + '\n\n*(truncated to fit GitHub)*';
  }
  return out;
}

module.exports = async function upsert({ github, context, kind, body }) {
  const { owner, repo } = context.repo;
  const issue_number = context.issue.number;
  const comments = await github.paginate(github.rest.issues.listComments, {
    owner, repo, issue_number, per_page: 100,
  });
  // Oldest first, so the last match is the newest.
  const ours = comments.filter((c) => isOurs(c, kind));
  const keep = ours.length ? ours[ours.length - 1] : null;
  const fullBody = render(kind, body, context.runNumber, context.runId, keep ? currentPart(keep.body) : '');

  if (keep) {
    await github.rest.issues.updateComment({ owner, repo, comment_id: keep.id, body: fullBody });
    console.log(`Updated ${kind} comment ${keep.id}`);
  } else {
    await github.rest.issues.createComment({ owner, repo, issue_number, body: fullBody });
    console.log(`Created ${kind} comment`);
  }
  for (const stale of ours.slice(0, -1)) {
    await github.rest.issues.deleteComment({ owner, repo, comment_id: stale.id });
    console.log(`Deleted stale ${kind} comment ${stale.id}`);
  }
};

module.exports.marker = marker;
module.exports.render = render;
module.exports.currentPart = currentPart;
