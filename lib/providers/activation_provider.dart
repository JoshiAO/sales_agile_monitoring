import 'package:flutter/material.dart';
import 'package:compact_sales_monitoring/services/activation_service.dart';

class ActivationProvider extends ChangeNotifier {
  final ActivationService _activationService = ActivationService();

  bool _isChecking = true;
  bool _isActivating = false;
  bool _isActivated = false;
  String? _error;
  int _daysSinceLastLeaseCheck = 0;
  String? _leaseStatusMessage;

  bool get isChecking => _isChecking;
  bool get isActivating => _isActivating;
  bool get isActivated => _isActivated;
  String? get error => _error;
  int get daysSinceLastLeaseCheck => _daysSinceLastLeaseCheck;
  String? get leaseStatusMessage => _leaseStatusMessage;
  bool get isLeaseStatusUrgent => _daysSinceLastLeaseCheck >= 14;

  Future<void> _updateLeaseStatus() async {
    _daysSinceLastLeaseCheck =
        await _activationService.daysSinceLastSuccessfulLeaseCheck();

    if (!_isActivated) {
      _leaseStatusMessage = null;
      return;
    }

    if (_daysSinceLastLeaseCheck >=
        ActivationService.leaseRenewalIntervalDays) {
      final remainingDays =
          ActivationService.manualReactivationThresholdDays -
              _daysSinceLastLeaseCheck;

      if (remainingDays > 0) {
        _leaseStatusMessage =
            'Day $_daysSinceLastLeaseCheck/20 since last online check. Connect to internet within $remainingDays day(s) to keep auto-renew active.';
      } else {
        _leaseStatusMessage =
            'Day $_daysSinceLastLeaseCheck/20 reached. Manual reactivation is now required.';
      }
      return;
    }

    _leaseStatusMessage = null;
  }

  Future<void> initialize() async {
    try {
      _isChecking = true;
      _error = null;
      notifyListeners();

      _isActivated = await _activationService.isActivatedLocally();

      if (_isActivated) {
        final requiresManual = await _activationService.requiresManualReactivation();
        if (requiresManual) {
          await _activationService.clearActivation();
          _isActivated = false;
          _error = 'Activation expired after 20 days offline. Please enter your company code again.';
        }

        final shouldRefresh = await _activationService.shouldRefreshLease();
        if (_isActivated && shouldRefresh) {
          _isActivated = await _activationService.refreshLease();
          if (!_isActivated) {
            _error = 'Unable to renew activation. Please connect to the internet or re-enter your company code.';
          }
        }
      }

      await _updateLeaseStatus();
    } catch (e) {
      _isActivated = false;
      _error = 'Failed to load activation status.';
      _leaseStatusMessage = null;
    } finally {
      _isChecking = false;
      notifyListeners();
    }
  }

  Future<bool> activate(String companyCode) async {
    _isActivating = true;
    _error = null;
    notifyListeners();

    try {
      await _activationService.activateWithCompanyCode(companyCode);
      _isActivated = true;
      await _updateLeaseStatus();
      return true;
    } catch (e) {
      _error = e.toString().replaceFirst('Exception: ', '');
      return false;
    } finally {
      _isActivating = false;
      notifyListeners();
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
