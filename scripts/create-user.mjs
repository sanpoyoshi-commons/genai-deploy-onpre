// 一般ユーザー作成／招待（招待制オンボーディング）。
//
// 上流クラウド版は Cognito User Pool のセルフサインアップ／管理画面でユーザーを供給したが、
// オンプレ版は self-signup を OFF 維持（realm registrationAllowed:false）し、管理者が
// Keycloak Admin REST でユーザーを作成する。サービスアカウント client（genai-ai-api-admin・
// client_credentials・realm-management manage-users）でトークンを取得し、
//   1. email exact 事前チェック（冪等：既存ならスキップ）
//   2. POST /users（groups=[/User], requiredActions=[UPDATE_PASSWORD], emailVerified:false）
//   3. 任意で execute-actions-email（UPDATE_PASSWORD+VERIFY_EMAIL）→ Mailpit に招待リンク着信
// realm の defaultGroups=[/User] でも User 付与されるが、明示指定で確実にする。
//
// 実行（deploy リポで、api コンテナ内・内部ネットワーク http://keycloak:8080 を使う）：
//   set -a && . ./.env && set +a && \
//   docker compose exec -T \
//     -e KEYCLOAK_ADMIN_CLIENT_SECRET="$KEYCLOAK_ADMIN_CLIENT_SECRET" \
//     -e NEW_USER_EMAIL="user@example.com" \
//     -e SEND_INVITE=1 \
//     api node --input-type=module - < scripts/create-user.mjs
//
// secrets オーバーレイ運用時は client secret が /run/secrets にあるため -e は不要（_FILE を自動解決）。
// パスワードや secret は標準出力に出さない。

import { readFileSync } from 'node:fs';

/** docker secrets（`${NAME}_FILE`）優先・素の env フォールバックで秘密値を読む。 */
function readSecret(name) {
  const file = process.env[`${name}_FILE`];
  if (file) {
    return readFileSync(file, 'utf8').trim();
  }
  return process.env[name];
}

const BASE = (process.env.KEYCLOAK_ADMIN_BASE_URL ?? 'http://keycloak:8080').replace(/\/$/, '');
const REALM = process.env.KEYCLOAK_ADMIN_REALM ?? 'genai-realm';
const CLIENT_ID = process.env.KEYCLOAK_ADMIN_CLIENT_ID ?? 'genai-ai-api-admin';
const CLIENT_SECRET = readSecret('KEYCLOAK_ADMIN_CLIENT_SECRET');

const email = process.env.NEW_USER_EMAIL;
const username = process.env.NEW_USER_USERNAME ?? email;
const firstName = process.env.NEW_USER_FIRST; // 任意（未設定なら初回ログイン時にプロファイル補完）
const lastName = process.env.NEW_USER_LAST; // 任意
// 招待メール送信（既定 ON）。Keycloak realm に smtpServer 配線済み（Mailpit）が前提。
const sendInvite = (process.env.SEND_INVITE ?? '1') !== '0';
// execute-actions-email の redirect 先 client / URL（genai-web の許可済 redirect）。
const inviteClientId = process.env.INVITE_CLIENT_ID ?? 'genai-web';
const inviteRedirectUri = process.env.INVITE_REDIRECT_URI ?? 'https://localhost/';

if (!email) {
  console.error('NEW_USER_EMAIL が未設定です。-e NEW_USER_EMAIL="user@example.com" を渡してください。');
  process.exit(1);
}
if (!CLIENT_SECRET) {
  console.error('KEYCLOAK_ADMIN_CLIENT_SECRET（または _FILE）が未設定です。');
  process.exit(1);
}

/** サービスアカウント client_credentials で管理トークンを取得。 */
async function getAdminToken() {
  const res = await fetch(`${BASE}/realms/${encodeURIComponent(REALM)}/protocol/openid-connect/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: 'client_credentials', client_id: CLIENT_ID, client_secret: CLIENT_SECRET }),
  });
  if (!res.ok) {
    throw new Error(`admin token request failed: ${res.status}`);
  }
  const j = await res.json();
  if (!j.access_token) {
    throw new Error('admin token response missing access_token');
  }
  return j.access_token;
}

const token = await getAdminToken();
const authz = { authorization: `Bearer ${token}` };

// 1. 既存チェック（冪等）。
const findRes = await fetch(
  `${BASE}/admin/realms/${encodeURIComponent(REALM)}/users?email=${encodeURIComponent(email)}&exact=true`,
  { headers: authz },
);
if (!findRes.ok) {
  console.error(`[find] 失敗 status=${findRes.status}`);
  process.exit(1);
}
const existing = await findRes.json();
let userId = Array.isArray(existing) ? existing.find((u) => typeof u.id === 'string')?.id : undefined;

if (userId) {
  console.log(`[create-user] 既存ユーザーをスキップ（冪等）: ${email} (id=${userId})`);
} else {
  // 2. 作成。
  const userRep = {
    username,
    email,
    enabled: true,
    emailVerified: false,
    groups: ['/User'],
    requiredActions: ['UPDATE_PASSWORD'],
    ...(firstName ? { firstName } : {}),
    ...(lastName ? { lastName } : {}),
  };
  const createRes = await fetch(`${BASE}/admin/realms/${encodeURIComponent(REALM)}/users`, {
    method: 'POST',
    headers: { ...authz, 'content-type': 'application/json' },
    body: JSON.stringify(userRep),
  });
  if (createRes.status !== 201) {
    console.error(`[create] 失敗 status=${createRes.status} body=${await createRes.text()}`);
    process.exit(1);
  }
  // Location ヘッダ末尾が user id。無い場合は再 query。
  const loc = createRes.headers.get('location');
  userId = loc ? loc.split('/').pop() : undefined;
  if (!userId) {
    const reRes = await fetch(
      `${BASE}/admin/realms/${encodeURIComponent(REALM)}/users?email=${encodeURIComponent(email)}&exact=true`,
      { headers: authz },
    );
    const reList = await reRes.json();
    userId = Array.isArray(reList) ? reList.find((u) => typeof u.id === 'string')?.id : undefined;
  }
  console.log(`[create-user] 作成: ${email} (id=${userId}) groups=[/User]`);
}

// 3. 招待メール（任意）。
if (sendInvite && userId) {
  const url =
    `${BASE}/admin/realms/${encodeURIComponent(REALM)}/users/${encodeURIComponent(userId)}/execute-actions-email` +
    `?client_id=${encodeURIComponent(inviteClientId)}&redirect_uri=${encodeURIComponent(inviteRedirectUri)}`;
  const mailRes = await fetch(url, {
    method: 'PUT',
    headers: { ...authz, 'content-type': 'application/json' },
    body: JSON.stringify(['UPDATE_PASSWORD', 'VERIFY_EMAIL']),
  });
  if (!mailRes.ok) {
    console.error(`[invite] 招待メール送信失敗 status=${mailRes.status} body=${await mailRes.text()}`);
    console.error('  → realm の smtpServer 配線（Mailpit）と client redirect 許可を確認してください。');
    process.exit(1);
  }
  console.log(`[create-user] 招待メール送信: ${email}（Mailpit UI :8025 で確認 → リンクからパスワード設定）`);
} else if (!sendInvite) {
  console.log('[create-user] SEND_INVITE=0 のため招待メールはスキップ（パスワードは Admin Console で設定）。');
}

console.log('[result] create-user OK');
