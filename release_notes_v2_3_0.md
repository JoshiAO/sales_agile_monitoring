# Release v2.3.0 - US Storage Bucket Migration, Package Rename, Admin Database Page & Security Hardening

## Executive Summary
Version 2.3.0 migrates Firebase Storage to the Always Free US regional bucket (`gs://sales-team-stream-monitoring`), renames the Android application package to `com.agile.app.jao`, introduces the **Encoder** role, **Salesman Classification** (defaulting all salesmen to **Booking** for this release), the Admin **Database** page with separated Archive & Image Deletion, and comprehensive security, reliability, and UI quality improvements.

> **Note:** The Transactions page is marked **Under Development** and the Android PDF Interceptor is disabled in `v2.3.0` while the Storage bucket transition completes. All salesmen default to **Booking** (`Calls` + `Agile`).

---

## Highlights
- **Firebase Storage US Bucket Migration**: Switched active storage bucket to `gs://sales-team-stream-monitoring` across Web, Android, iOS, macOS, and Windows configs.
- **Android Package Rename**: Migrated Android package/namespace/applicationId from `com.example.compact_sales_monitoring` to `com.agile.app.jao` with updated Firebase app registration (`google-services.json` & `firebase_options.dart`).
- **Admin Database Page**: Moved Archive out of the Map page into a dedicated **Database** tab with strictly separated **Archive Saved Images (Download ZIP)** and **Delete Saved Images (Storage only — preserves GPS & transactions)**.
- **Role & Classification Framework**: Added the **Encoder** role (Home + Transactions), optional salesman Encoder assignment, and `Booking` / `Van Ex-Truck` salesman classification (defaulting to `Booking` in v2.3.0).
- **UI & Navigation Cleanup**: Removed Feeds & Announcements from mobile and web navigation; relocated the mobile Logout Status pill from the header overlay to top-left inside the Calls page; redesigned the web Route Detail modal; fixed responsive card layouts and overflows.
- **Security & Reliability Hardening (Audit Phases 1–4)**: Enforced strict `company_ID` multi-tenant isolation in `firestore.rules` & `storage.rules`, added missing composite indexes, hardened Android native & background sync concurrency, and eliminated Flutter controller/mounted lifecycle leaks.

