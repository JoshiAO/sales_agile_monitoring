class CompanyBranding {
  final String companyId;
  final String? logoUrl;
  final String? tagline;

  const CompanyBranding({
    required this.companyId,
    this.logoUrl,
    this.tagline,
  });

  factory CompanyBranding.fromMap(
    Map<String, dynamic> data,
    String companyId,
  ) {
    final rawLogo =
        data['logo'] ?? data['logoUrl'] ?? data['company_logo'] ?? data['Logo'];
    final rawTagline =
        data['tagline'] ?? data['company_tagline'] ?? data['Tagline'];

    return CompanyBranding(
      companyId: companyId,
      logoUrl: rawLogo is String ? rawLogo : null,
      tagline: rawTagline is String ? rawTagline : null,
    );
  }

  Map<String, dynamic> toMap() => {
    'logo': logoUrl,
    'tagline': tagline,
  };
}
