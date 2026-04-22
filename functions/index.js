const functions = require('firebase-functions');
const admin = require('firebase-admin');

admin.initializeApp();

exports.adminUpdateUserCredentials = functions.https.onCall(async (data, context) => {
  if (!context.auth?.uid) {
    throw new functions.https.HttpsError('unauthenticated', 'You must be signed in.');
  }

  const callerUid = context.auth.uid;
  const callerDoc = await admin.firestore().collection('users').doc(callerUid).get();
  const callerRole = callerDoc.data()?.role;

  if (callerRole !== 'superuser') {
    throw new functions.https.HttpsError('permission-denied', 'Only superusers can update credentials.');
  }

  const uid = (data?.uid || '').toString().trim();
  const email = data?.email == null ? null : data.email.toString().trim().toLowerCase();
  const password = data?.password == null ? null : data.password.toString();

  if (!uid) {
    throw new functions.https.HttpsError('invalid-argument', 'uid is required.');
  }

  const updates = {};
  if (email) {
    updates.email = email;
  }
  if (password) {
    if (password.length < 6) {
      throw new functions.https.HttpsError('invalid-argument', 'Password must be at least 6 characters.');
    }
    updates.password = password;
  }

  if (Object.keys(updates).length === 0) {
    throw new functions.https.HttpsError(
      'invalid-argument',
      'At least one of email or password is required.'
    );
  }

  try {
    await admin.auth().updateUser(uid, updates);
    return { success: true };
  } catch (error) {
    throw new functions.https.HttpsError('internal', error.message || 'Failed to update auth user.');
  }
});
