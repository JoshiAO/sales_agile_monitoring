const admin = require('firebase-admin');

if (!process.env.GOOGLE_APPLICATION_CREDENTIALS) {
  console.error('Missing GOOGLE_APPLICATION_CREDENTIALS.');
  process.exit(1);
}

admin.initializeApp({ credential: admin.credential.applicationDefault() });

const auth = admin.auth();
const db = admin.firestore();

const DEFAULT_PASSWORD = process.env.SEED_DEFAULT_PASSWORD || 'ChangeMe123!';

// Supervisor UIDs will be resolved after auth creation
// supervisorEmail field is used as a placeholder; replaced with UID below
const users = [
  { email: 'superuser@example.com', password: DEFAULT_PASSWORD, role: 'superuser', active: true, supervisorEmail: null },
  { email: 'supervisor.a@example.com', password: DEFAULT_PASSWORD, role: 'supervisor', active: true, supervisorEmail: null },
  { email: 'supervisor.b@example.com', password: DEFAULT_PASSWORD, role: 'supervisor', active: true, supervisorEmail: null },
  { email: 'salesman01@example.com', password: DEFAULT_PASSWORD, role: 'salesman', active: true, supervisorEmail: 'supervisor.a@example.com' },
  { email: 'salesman02@example.com', password: DEFAULT_PASSWORD, role: 'salesman', active: true, supervisorEmail: 'supervisor.a@example.com' },
  { email: 'salesman03@example.com', password: DEFAULT_PASSWORD, role: 'salesman', active: true, supervisorEmail: 'supervisor.a@example.com' },
  { email: 'salesman04@example.com', password: DEFAULT_PASSWORD, role: 'salesman', active: true, supervisorEmail: 'supervisor.a@example.com' },
  { email: 'salesman05@example.com', password: DEFAULT_PASSWORD, role: 'salesman', active: true, supervisorEmail: 'supervisor.a@example.com' },
  { email: 'salesman06@example.com', password: DEFAULT_PASSWORD, role: 'salesman', active: true, supervisorEmail: 'supervisor.a@example.com' },
  { email: 'salesman07@example.com', password: DEFAULT_PASSWORD, role: 'salesman', active: true, supervisorEmail: 'supervisor.b@example.com' },
  { email: 'salesman08@example.com', password: DEFAULT_PASSWORD, role: 'salesman', active: true, supervisorEmail: 'supervisor.b@example.com' },
  { email: 'salesman09@example.com', password: DEFAULT_PASSWORD, role: 'salesman', active: false, supervisorEmail: 'supervisor.b@example.com' },
  { email: 'salesman10@example.com', password: DEFAULT_PASSWORD, role: 'salesman', active: true, supervisorEmail: 'supervisor.b@example.com' },
];

async function run() {
  const emailToUid = {};

  console.log('\n--- Step 1: Create Auth users ---');
  for (const u of users) {
    try {
      // Try to get existing user first
      let authUser;
      try {
        authUser = await auth.getUserByEmail(u.email);
        console.log(`EXISTS  ${u.email} -> ${authUser.uid}`);
      } catch {
        authUser = await auth.createUser({ email: u.email, password: u.password });
        console.log(`CREATED ${u.email} -> ${authUser.uid}`);
      }
      emailToUid[u.email.toLowerCase()] = authUser.uid;
    } catch (e) {
      console.error(`FAIL    ${u.email} -> ${e.message}`);
    }
  }

  console.log('\n--- Step 2: Write Firestore documents ---');
  let ok = 0, fail = 0;
  for (const u of users) {
    const uid = emailToUid[u.email.toLowerCase()];
    if (!uid) { console.error(`SKIP (no uid) ${u.email}`); fail++; continue; }

    const supervisorId = u.supervisorEmail
      ? (emailToUid[u.supervisorEmail.toLowerCase()] ?? null)
      : null;

    try {
      await db.collection('users').doc(uid).set({
        email: u.email,
        role: u.role,
        active: u.active,
        supervisorId,
        profilePic: null,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      }, { merge: true });
      console.log(`OK  ${u.email} -> users/${uid}  supervisorId=${supervisorId}`);
      ok++;
    } catch (e) {
      console.error(`FAIL ${u.email} -> ${e.message}`);
      fail++;
    }
  }

  console.log(`\n--- Done: ${ok} success, ${fail} failed ---`);
  process.exit(fail > 0 ? 1 : 0);
}

run().catch(e => { console.error(e); process.exit(1); });
