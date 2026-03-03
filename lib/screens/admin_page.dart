import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/pothole.dart';
import 'login_page.dart';

class AdminPage extends StatefulWidget {
  const AdminPage({super.key});

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF8F9FA),
      appBar: AppBar(
        title: const Text(
          'Admin Dashboard',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout, color: Colors.red),
            onPressed: () {
              Navigator.pushReplacement(
                context,
                MaterialPageRoute(builder: (context) => const LoginPage()),
              );
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSummaryStats(),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Recent Reports',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('potholes')
                  .orderBy('timestamp', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snapshot.hasError) {
                  return Center(child: Text('Error: ${snapshot.error}'));
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return const Center(child: Text('No potholes reported.'));
                }

                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: snapshot.data!.docs.length,
                  itemBuilder: (context, index) {
                    var doc = snapshot.data!.docs[index];
                    var pothole = Pothole.fromMap(
                      doc.id,
                      doc.data() as Map<String, dynamic>,
                    );
                    return _buildAdminPotholeCard(pothole);
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryStats() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('potholes').snapshots(),
      builder: (context, snapshot) {
        int total = snapshot.hasData ? snapshot.data!.docs.length : 0;
        int fixed = snapshot.hasData
            ? snapshot.data!.docs.where((d) => d['status'] == 'fixed').length
            : 0;
        int pending = total - fixed;

        return Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              _buildStatBox("Total", total.toString(), Colors.blue),
              const SizedBox(width: 12),
              _buildStatBox("Pending", pending.toString(), Colors.orange),
              const SizedBox(width: 12),
              _buildStatBox("Fixed", fixed.toString(), Colors.green),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStatBox(String label, String value, Color color) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: color.withOpacity(0.1),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdminPotholeCard(Pothole pothole) {
    bool isFixed = pothole.status.toLowerCase() == 'fixed';

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 2,
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: _getSeverityColor(pothole.severity).withOpacity(0.2),
          child: Icon(
            Icons.warning,
            color: _getSeverityColor(pothole.severity),
            size: 20,
          ),
        ),
        title: Text(
          pothole.description.isEmpty ? "No description" : pothole.description,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text("Status: ${pothole.status}"),
        trailing: Switch(
          value: isFixed,
          onChanged: (bool value) {
            _togglePotholeStatus(pothole.id, value);
          },
          activeColor: Colors.green,
        ),
        children: [
          if (pothole.imageUrl != null)
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.network(
                  pothole.imageUrl!,
                  height: 200,
                  width: double.infinity,
                  fit: BoxFit.cover,
                  cacheWidth: 800, // Optimize memory for admin view
                  errorBuilder: (context, error, stackTrace) =>
                      const Icon(Icons.broken_image, size: 50),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  "Severity: ${pothole.severity}",
                  style: TextStyle(
                    color: _getSeverityColor(pothole.severity),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  "Location: ${pothole.point.latitude.toStringAsFixed(4)}, ${pothole.point.longitude.toStringAsFixed(4)}",
                ),
              ],
            ),
          ),
          ButtonBar(
            children: [
              TextButton.icon(
                onPressed: () {
                  FirebaseFirestore.instance
                      .collection('potholes')
                      .doc(pothole.id)
                      .delete();
                },
                icon: const Icon(Icons.delete, color: Colors.red),
                label: const Text(
                  "Delete",
                  style: TextStyle(color: Colors.red),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Color _getSeverityColor(String severity) {
    switch (severity.toLowerCase()) {
      case 'high':
        return Colors.red;
      case 'medium':
        return Colors.orange;
      case 'low':
        return Colors.yellow[700]!;
      default:
        return Colors.blue;
    }
  }

  Future<void> _togglePotholeStatus(String id, bool isCompleted) async {
    await FirebaseFirestore.instance.collection('potholes').doc(id).update({
      'status': isCompleted ? 'fixed' : 'Pending',
    });
  }
}
