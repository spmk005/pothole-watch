import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class TestVideoPage extends StatefulWidget {
  const TestVideoPage({super.key});

  @override
  State<TestVideoPage> createState() => _TestVideoPageState();
}

class _TestVideoPageState extends State<TestVideoPage> {
  final ImagePicker _picker = ImagePicker();
  File? _videoFile;
  bool _isProcessing = false;

  Future<void> _pickVideo() async {
    final XFile? pickedFile = await _picker.pickVideo(
      source: ImageSource.gallery,
    );
    if (pickedFile != null) {
      setState(() {
        _videoFile = File(pickedFile.path);
        _isProcessing = false;
      });
      // TODO: Logic to extract frames and pass to YOLO model goes here
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text(
          'Analyze Video',
          style: TextStyle(color: Colors.white),
        ),
        backgroundColor: Colors.black87,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Expanded(
            child: Center(
              child: _videoFile == null
                  ? const Text(
                      'Please select an MP4 video file.',
                      style: TextStyle(color: Colors.white70),
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(
                          Icons.video_file,
                          color: Colors.blueAccent,
                          size: 100,
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'Selected: ${_videoFile!.path.split('/').last}',
                          style: const TextStyle(color: Colors.white),
                        ),
                        const SizedBox(height: 20),
                        if (_isProcessing)
                          const CircularProgressIndicator(
                            color: Colors.redAccent,
                          )
                        else
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.redAccent,
                            ),
                            onPressed: () {
                              setState(() => _isProcessing = true);
                              // Trigger processing logic
                            },
                            icon: const Icon(
                              Icons.play_arrow,
                              color: Colors.white,
                            ),
                            label: const Text(
                              "Process Video",
                              style: TextStyle(color: Colors.white),
                            ),
                          ),
                      ],
                    ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(20),
            color: Colors.grey[900],
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ElevatedButton.icon(
                  onPressed: _pickVideo,
                  icon: const Icon(Icons.video_library),
                  label: const Text("Pick Video from Gallery"),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
