const functions = require('firebase-functions/v1');
const admin = require('firebase-admin');
const crypto = require('crypto');

admin.initializeApp();

const ACTIVATION_PROJECT_ID = 'joshiao-active-projects';
const ACTIVATION_APP_NAME = 'activation-project';
const ACTIVATION_COLLECTION = 'company_codes';
const ACTIVATION_LEASE_DAYS = 7;

let activationFirestore;

function getActivationFirestore() {
  if (activationFirestore) {
    return activationFirestore;
  }

  const existingApp = admin.apps.find((app) => app.name === ACTIVATION_APP_NAME);
  const activationApp =
    existingApp ?? admin.initializeApp({ projectId: ACTIVATION_PROJECT_ID }, ACTIVATION_APP_NAME);

  activationFirestore = admin.firestore(activationApp);
  return activationFirestore;
}

function evaluateActivationPayload(payload) {
  const active = payload.active !== false;
  const expiresAt = payload.expiresAt?.toDate ? payload.expiresAt.toDate() : null;
  const isExpired = expiresAt ? expiresAt.getTime() <= Date.now() : false;

  return {
    valid: active && !isExpired,
    companyName: payload.companyName || null,
  };
}

async function getCodeDocByRawCode(activationDb, rawCode) {
  const hashedCode = crypto.createHash('sha256').update(rawCode).digest('hex');

  // Prefer hashed document IDs for stronger secrecy at rest.
  let codeDoc = await activationDb.collection(ACTIVATION_COLLECTION).doc(hashedCode).get();
  let leaseKey = hashedCode;

  // Backward compatibility if you still have plaintext doc IDs.
  if (!codeDoc.exists) {
    codeDoc = await activationDb.collection(ACTIVATION_COLLECTION).doc(rawCode).get();
    if (codeDoc.exists) {
      leaseKey = rawCode;
    }
  }

  return {
    codeDoc,
    leaseKey,
  };
}

exports.validateCompanyCode = functions
  .region('us-central1')
  .https.onCall(async (data) => {
    const rawCode = (data?.companyCode || '').toString().trim().toUpperCase();

    // Keep input strict to reduce brute-force attempts and accidental invalid values.
    if (!rawCode || rawCode.length < 6 || rawCode.length > 64) {
      throw new functions.https.HttpsError('invalid-argument', 'Please enter a valid company code.');
    }

    if (!/^[A-Z0-9_-]+$/.test(rawCode)) {
      throw new functions.https.HttpsError('invalid-argument', 'Please enter a valid company code.');
    }

    try {
      const activationDb = getActivationFirestore();
      const { codeDoc, leaseKey } = await getCodeDocByRawCode(activationDb, rawCode);

      if (!codeDoc.exists) {
        return { valid: false };
      }

      const payload = codeDoc.data() || {};
      const evaluation = evaluateActivationPayload(payload);

      if (!evaluation.valid) {
        return { valid: false };
      }

      return {
        valid: true,
        companyName: evaluation.companyName,
        leaseKey,
        leaseDurationDays: ACTIVATION_LEASE_DAYS,
      };
    } catch (error) {
      throw new functions.https.HttpsError('internal', error.message || 'Failed to validate company code.');
    }
  });

exports.refreshActivationLease = functions
  .region('us-central1')
  .https.onCall(async (data) => {
    const leaseKey = (data?.leaseKey || '').toString().trim();

    if (!leaseKey || leaseKey.length < 6 || leaseKey.length > 128) {
      throw new functions.https.HttpsError('invalid-argument', 'Invalid activation lease key.');
    }

    if (!/^[A-Za-z0-9_-]+$/.test(leaseKey)) {
      throw new functions.https.HttpsError('invalid-argument', 'Invalid activation lease key.');
    }

    try {
      const activationDb = getActivationFirestore();
      const codeDoc = await activationDb.collection(ACTIVATION_COLLECTION).doc(leaseKey).get();

      if (!codeDoc.exists) {
        return { valid: false };
      }

      const payload = codeDoc.data() || {};
      const evaluation = evaluateActivationPayload(payload);

      return {
        valid: evaluation.valid,
        companyName: evaluation.companyName,
        leaseDurationDays: ACTIVATION_LEASE_DAYS,
      };
    } catch (error) {
      throw new functions.https.HttpsError('internal', error.message || 'Failed to refresh activation lease.');
    }
  });

exports.adminUpdateUserCredentials = functions
  .region('us-central1')
  .https.onCall(async (data, context) => {
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
