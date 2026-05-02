import 'package:cloud_functions/cloud_functions.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ActivationService {
  static final ActivationService _instance = ActivationService._internal();

  factory ActivationService() {
    return _instance;
  }

  ActivationService._internal();

  static const String _activationKey = 'company_code_activated';
  static const String _activationLeaseKey = 'company_code_activation_lease_key';
  static const String _activationLeaseCheckedAtKey = 'company_code_activation_checked_at_ms';
  static const int leaseRenewalIntervalDays = 7;
  static const int manualReactivationThresholdDays = 20;

  final FirebaseFunctions _functions = FirebaseFunctions.instanceFor(region: 'us-central1');

  Future<bool> isActivatedLocally() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_activationKey) ?? false;
  }

  Future<bool> shouldRefreshLease() async {
    final elapsedDays = await daysSinceLastSuccessfulLeaseCheck();
    return elapsedDays >= leaseRenewalIntervalDays;
  }

  Future<int> daysSinceLastSuccessfulLeaseCheck() async {
    final prefs = await SharedPreferences.getInstance();
    final checkedAtMs = prefs.getInt(_activationLeaseCheckedAtKey);

    if (checkedAtMs == null) {
      return manualReactivationThresholdDays;
    }

    final checkedAt = DateTime.fromMillisecondsSinceEpoch(checkedAtMs);
    final elapsed = DateTime.now().difference(checkedAt);
    return elapsed.inDays;
  }

  Future<bool> requiresManualReactivation() async {
    final elapsedDays = await daysSinceLastSuccessfulLeaseCheck();
    return elapsedDays >= manualReactivationThresholdDays;
  }

  Future<void> activateWithCompanyCode(String companyCode) async {
    final normalizedCode = companyCode.trim().toUpperCase();

    if (normalizedCode.isEmpty) {
      throw Exception('Company code is required.');
    }

    try {
      final callable = _functions.httpsCallable('validateCompanyCode');
      final result = await callable.call(<String, dynamic>{
        'companyCode': normalizedCode,
      });

      final data = (result.data as Map?) ?? <String, dynamic>{};
      final isValid = data['valid'] == true;
      final leaseKey = (data['leaseKey'] ?? '').toString();

      if (!isValid || leaseKey.isEmpty) {
        throw Exception('Invalid company code.');
      }

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_activationKey, true);
      await prefs.setString(_activationLeaseKey, leaseKey);
      await prefs.setInt(
        _activationLeaseCheckedAtKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    } on FirebaseFunctionsException catch (e) {
      throw Exception(e.message ?? 'Unable to validate company code.');
    }
  }

  Future<bool> refreshLease() async {
    final prefs = await SharedPreferences.getInstance();
    final leaseKey = prefs.getString(_activationLeaseKey);

    if (leaseKey == null || leaseKey.isEmpty) {
      await clearActivation();
      return false;
    }

    try {
      final callable = _functions.httpsCallable('refreshActivationLease');
      final result = await callable.call(<String, dynamic>{
        'leaseKey': leaseKey,
      });

      final data = (result.data as Map?) ?? <String, dynamic>{};
      final isValid = data['valid'] == true;

      if (!isValid) {
        await clearActivation();
        return false;
      }

      await prefs.setInt(
        _activationLeaseCheckedAtKey,
        DateTime.now().millisecondsSinceEpoch,
      );
      await prefs.setBool(_activationKey, true);
      return true;
    } on FirebaseFunctionsException catch (e) {
      // Before 20 days, keep local activation on transient outages.
      if (e.code == 'unavailable') {
        final elapsedDays = await daysSinceLastSuccessfulLeaseCheck();
        if (elapsedDays < manualReactivationThresholdDays) {
          return prefs.getBool(_activationKey) ?? false;
        }
        await clearActivation();
        return false;
      }

      // Non-transient backend failures should deactivate to avoid stale access.
      await clearActivation();
      return false;
    } catch (_) {
      final elapsedDays = await daysSinceLastSuccessfulLeaseCheck();
      if (elapsedDays < manualReactivationThresholdDays) {
        return prefs.getBool(_activationKey) ?? false;
      }
      await clearActivation();
      return false;
    }
  }

  Future<void> clearActivation() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_activationKey);
    await prefs.remove(_activationLeaseKey);
    await prefs.remove(_activationLeaseCheckedAtKey);
  }

  Future<void> resetActivation() async {
    await clearActivation();
  }
}
