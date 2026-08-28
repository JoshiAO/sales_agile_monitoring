class AppConstants {
  // OpenRouteService API
  static const String openRouteServiceApiKey = 'YOUR_ORS_API_KEY_HERE';
  static const String openRouteServiceBaseUrl = 'https://api.openrouteservice.org';

  // Firestore Collections
  static const String usersCollection = 'users';
  static const String routesCollection = 'routes';

  // Firebase Storage Paths
  static const String profilePicsPath = 'profile_pictures';
  static const String routeImagesPath = 'route_images';

  // Date format
  static const String dateFormat = 'yyyy-MM-dd';

  // OpenStreetMap Tiles
  static const bool useOfflineTiles = false;
  static const String offlineTileUrl = 'assets/tiles/luzon/{z}/{x}/{y}.png';
  static const String offlineAttribution = 'Offline Luzon map tiles';
  static const String osmTileUrl = 'https://server.arcgisonline.com/ArcGIS/rest/services/Canvas/World_Light_Gray_Base/MapServer/tile/{z}/{y}/{x}';
  static const String osmAttribution = '© Esri, HERE, Garmin, OpenStreetMap contributors';
  static const String osmUserAgentPackage = 'com.joshiao.compact_sales_monitoring';
}
