const admin = require('firebase-admin');

if (!process.env.GOOGLE_APPLICATION_CREDENTIALS) {
  console.error('Missing GOOGLE_APPLICATION_CREDENTIALS.');
  console.error('Set it to your Firebase service account JSON path before running.');
  console.error('Project: <your-firebase-project-id>');
  process.exit(1);
}

admin.initializeApp({
  credential: admin.credential.applicationDefault(),
});

const db = admin.firestore();

const users = [
  {
    email: 'superuser@example.com',
    role: 'superuser',
    active: true,
    supervisorId: null,
    profilePic: null,
  },
  {
    email: 'supervisor.a@example.com',
    role: 'supervisor',
    active: true,
    supervisorId: null,
    profilePic: null,
  },
  {
    email: 'supervisor.b@example.com',
    role: 'supervisor',
    active: true,
    supervisorId: null,
    profilePic: null,
  },
  {
    email: 'salesman01@example.com',
    role: 'salesman',
    active: true,
    supervisorId: null,
    profilePic: null,
  },
  {
    email: 'salesman02@example.com',
    role: 'salesman',
    active: true,
    supervisorId: null,
    profilePic: null,
  },
  {
    email: 'salesman03@example.com',
    role: 'salesman',
    active: true,
    supervisorId: null,
    profilePic: null,
  },
  {
    email: 'salesman04@example.com',
    role: 'salesman',
    active: true,
    supervisorId: null,
    profilePic: null,
  },
  {
    email: 'salesman05@example.com',
    role: 'salesman',
    active: true,
    supervisorId: null,
    profilePic: null,
  },
  {
    email: 'salesman06@example.com',
    role: 'salesman',
    active: true,
    supervisorId: null,
    profilePic: null,
  },
  {
    email: 'salesman07@example.com',
    role: 'salesman',
    active: true,
    supervisorId: null,
    profilePic: null,
  },
  {
    email: 'salesman08@example.com',
    role: 'salesman',
    active: true,
    supervisorId: null,
    profilePic: null,
  },
  {
    email: 'salesman09@example.com',
    role: 'salesman',
    active: false,
    supervisorId: null,
    profilePic: null,
  },
  {
    email: 'salesman10@example.com',
    role: 'salesman',
    active: true,
    supervisorId: null,
    profilePic: null,
  },
];

async function upsertUsers() {
  let ok = 0;
  let fail = 0;

  for (const item of users) {
    try {
      const authUser = await admin.auth().getUserByEmail(item.email);

      await db.collection('users').doc(authUser.uid).set(
        {
          email: item.email,
          role: item.role,
          active: item.active,
          supervisorId: item.supervisorId,
          profilePic: item.profilePic,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true }
      );

      console.log(`OK  ${item.email} -> users/${authUser.uid}`);
      ok += 1;
    } catch (error) {
      console.error(`FAIL ${item.email} -> ${error.message}`);
      fail += 1;
    }
  }

  console.log('--- Done ---');
  console.log(`Success: ${ok}`);
  console.log(`Failed:  ${fail}`);

  process.exit(fail > 0 ? 1 : 0);
}

upsertUsers().catch((error) => {
  console.error(error);
  process.exit(1);
});
