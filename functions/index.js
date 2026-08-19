const { onCall, HttpsError } = require('firebase-functions/v2/https');
const { onDocumentUpdated } = require('firebase-functions/v2/firestore');
const { setGlobalOptions } = require('firebase-functions/v2');
const admin = require('firebase-admin');
const crypto = require('crypto');

admin.initializeApp();

// Set global defaults for all v2 functions
setGlobalOptions({
  region: 'us-central1',
  maxInstances: 10,
});

const ACTIVATION_PROJECT_ID = 'joshiao-active-projects';
const ACTIVATION_APP_NAME = 'activation-project';
const ACTIVATION_COLLECTION = 'company_codes';
const ACTIVATION_LEASE_DAYS = 7;
const FCM_MAX_RETRIES = 4;

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

function delay(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function isTransientFcmError(error) {
  const code = (error && error.code ? String(error.code) : '').toLowerCase();
  const message = (error && error.message ? String(error.message) : '').toLowerCase();

  return (
    code.includes('unavailable') ||
    code.includes('internal') ||
    code.includes('deadline-exceeded') ||
    code.includes('resource-exhausted') ||
    message.includes('temporar') ||
    message.includes('timeout')
  );
}

async function sendFcmWithRetry(message) {
  let lastError;

  for (let attempt = 0; attempt < FCM_MAX_RETRIES; attempt++) {
    try {
      await admin.messaging().send(message);
      return;
    } catch (error) {
      lastError = error;

      const shouldRetry = isTransientFcmError(error) && attempt < FCM_MAX_RETRIES - 1;
      if (!shouldRetry) {
        throw error;
      }

      const backoffMs = 400 * Math.pow(2, attempt);
      await delay(backoffMs);
    }
  }

  throw lastError;
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

exports.validateCompanyCode = onCall(
  {
    timeoutSeconds: 30,
    memory: '256MiB',
    // Rate-limit: max 5 concurrent calls per instance to mitigate brute-force
    concurrency: 5,
  },
  async (request) => {
    const data = request.data;
    const rawCode = (data?.companyCode || '').toString().trim().toUpperCase();

    // Keep input strict to reduce brute-force attempts and accidental invalid values.
    if (!rawCode || rawCode.length < 6 || rawCode.length > 64) {
      throw new HttpsError('invalid-argument', 'Please enter a valid company code.');
    }

    if (!/^[A-Z0-9_-]+$/.test(rawCode)) {
      throw new HttpsError('invalid-argument', 'Please enter a valid company code.');
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
      throw new HttpsError('internal', error.message || 'Failed to validate company code.');
    }
  }
);

exports.refreshActivationLease = onCall(
  { timeoutSeconds: 30, memory: '256MiB', concurrency: 5 },
  async (request) => {
    const data = request.data;
    const leaseKey = (data?.leaseKey || '').toString().trim();

    if (!leaseKey || leaseKey.length < 6 || leaseKey.length > 128) {
      throw new HttpsError('invalid-argument', 'Invalid activation lease key.');
    }

    if (!/^[A-Za-z0-9_-]+$/.test(leaseKey)) {
      throw new HttpsError('invalid-argument', 'Invalid activation lease key.');
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
      throw new HttpsError('internal', error.message || 'Failed to refresh activation lease.');
    }
  }
);

exports.adminUpdateUserCredentials = onCall(
  { timeoutSeconds: 30, memory: '256MiB' },
  async (request) => {
    if (!request.auth?.uid) {
      throw new HttpsError('unauthenticated', 'You must be signed in.');
    }

    const callerUid = request.auth.uid;
    const callerDoc = await admin.firestore().collection('users').doc(callerUid).get();
    const callerRole = callerDoc.data()?.role;

    if (callerRole !== 'superuser') {
      throw new HttpsError('permission-denied', 'Only superusers can update credentials.');
    }

    const data = request.data;
    const uid = (data?.uid || '').toString().trim();
    const email = data?.email == null ? null : data.email.toString().trim().toLowerCase();
    const password = data?.password == null ? null : data.password.toString();

    if (!uid) {
      throw new HttpsError('invalid-argument', 'uid is required.');
    }

    const updates = {};
    if (email) {
      updates.email = email;
    }
    if (password) {
      if (password.length < 6) {
        throw new HttpsError('invalid-argument', 'Password must be at least 6 characters.');
      }
      updates.password = password;
    }

    if (Object.keys(updates).length === 0) {
      throw new HttpsError(
        'invalid-argument',
        'At least one of email or password is required.'
      );
    }

    try {
      await admin.auth().updateUser(uid, updates);
      return { success: true };
    } catch (error) {
      throw new HttpsError('internal', error.message || 'Failed to update auth user.');
    }
  }
);

exports.notifyLogoutRequestResolution = onDocumentUpdated(
  {
    document: 'users/{userId}',
    timeoutSeconds: 60,
    memory: '256MiB',
  },
  async (event) => {
    const before = event.data.before.data() || {};
    const after = event.data.after.data() || {};

    const beforeStatus = before.logoutRequestStatus || null;
    const afterStatus = after.logoutRequestStatus || null;

    if (beforeStatus === afterStatus) {
      return null;
    }

    if (afterStatus !== 'approved' && afterStatus !== 'rejected') {
      return null;
    }

    const token = after.fcmToken;
    if (!token) {
      return null;
    }

    const title = afterStatus === 'approved'
      ? 'Logout Request Approved'
      : 'Logout Request Rejected';
    const body = afterStatus === 'approved'
      ? 'Your logout request was approved. You can now log out.'
      : 'Your logout request was rejected by superuser.';

    const notificationData = {
      type: 'logout_request_resolution',
      status: afterStatus,
      userId: event.params.userId,
    };

    await event.data.after.ref.collection('notifications').add({
      title,
      message: body,
      status: afterStatus,
      type: 'logout_request_resolution',
      readAt: null,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
      meta: {
        resolvedBy: after.logoutResolvedBy || null,
        resolvedByName: after.logoutResolvedByName || null,
        resolvedAt: after.logoutResolvedAt || null,
      },
    });

    try {
      await sendFcmWithRetry({
        token,
        notification: {
          title,
          body,
        },
        data: notificationData,
      });
    } catch (error) {
      console.error('Failed to send logout resolution notification', {
        userId: event.params.userId,
        error: error.message || error,
      });
    }

    return null;
  }
);
