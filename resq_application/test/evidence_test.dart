import 'package:flutter_test/flutter_test.dart';
import 'package:resq_application/services/incident_data.dart';
import 'package:resq_application/shared/image_gallery_widget.dart';

void main() {
  test('Videos from the camera are recognized and sent as video', () {
    expect(IncidentData.isVideoFile('/data/user/0/cache/VID_2026.mp4'), isTrue);
    expect(IncidentData.isVideoFile('/cache/clip.MOV'), isTrue);
    expect(IncidentData.isVideoFile('/cache/IMG_2026.jpg'), isFalse);
  });

  test('Voice messages are recognized as audio, not as photo or video evidence', () {
    expect(IncidentData.isAudioFile('/cache/resq_voice_1.m4a'), isTrue);
    expect(IncidentData.isVideoFile('/cache/resq_voice_1.m4a'), isFalse);
    expect(IncidentData.isAudioFile('/cache/IMG_1.jpg'), isFalse);
  });

  test('A video shows a still picture and plays as MP4', () {
    const video = 'https://res.cloudinary.com/demo/video/upload/v1/abc.3gp';
    const photo = 'https://res.cloudinary.com/demo/image/upload/v1/abc.jpg';
    expect(isVideoUrl(video), isTrue);
    expect(isVideoUrl(photo), isFalse);
    expect(evidenceThumbUrl(video), 'https://res.cloudinary.com/demo/video/upload/v1/abc.jpg');
    expect(evidenceThumbUrl(photo), photo); // photos unchanged
  });
}
