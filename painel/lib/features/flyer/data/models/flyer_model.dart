class Flyer {
  final String id;
  final String thumbnailUrl;
  final String? videoUrl;
  final DateTime? createdAt;
  final bool timerEnabled;
  final DateTime? timerTargetTime;
  final double timerPosX;
  final double timerPosY;

  bool get hasVideo => videoUrl != null && videoUrl!.isNotEmpty;

  Flyer({
    required this.id,
    required this.thumbnailUrl,
    this.videoUrl,
    this.createdAt,
    this.timerEnabled = false,
    this.timerTargetTime,
    this.timerPosX = 0.0,
    this.timerPosY = 0.0,
  });

  factory Flyer.fromJson(Map<String, dynamic> json) {
    return Flyer(
      id: json['id']?.toString() ?? '',
      thumbnailUrl: json['thumbnail_url']?.toString() ?? 
                    json['thumbnailUrl']?.toString() ?? 
                    json['url']?.toString() ?? 
                    '',
      videoUrl: json['video_url']?.toString() ?? 
                json['videoUrl']?.toString(),
      createdAt: json['created_at'] != null && json['created_at'].toString().isNotEmpty
          ? DateTime.tryParse(json['created_at'].toString())
          : null,
      timerEnabled: json['timer_enabled'] == true,
      timerTargetTime: json['timer_target_time'] != null ? DateTime.tryParse(json['timer_target_time']) : null,
      timerPosX: (json['timer_pos_x'] ?? 0.0).toDouble(),
      timerPosY: (json['timer_pos_y'] ?? 0.0).toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'thumbnail_url': thumbnailUrl,
    'video_url': videoUrl,
    'created_at': createdAt?.toIso8601String(),
  };
}