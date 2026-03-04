import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/pothole.dart';
import 'admin_map_page.dart';
import 'login_page.dart';

class AdminPage extends StatefulWidget {
  const AdminPage({super.key});

  @override
  State<AdminPage> createState() => _AdminPageState();
}

class _AdminPageState extends State<AdminPage> {
  // Theme Colors - White Theme
  static const Color bgColor = Colors.white;
  static const Color cardBgColor = Color(0xFFF8FAFC);
  static const Color primaryOrange = Color(0xFFFF701D);
  static const Color textHigh = Color(0xFFB91414);
  static const Color bgHigh = Color(0xFFFEF2F2);
  static const Color textMed = Color(0xFFB45309);
  static const Color bgMed = Color(0xFFFFFBEB);
  static const Color textLow = Color(0xFF047857);
  static const Color bgLow = Color(0xFFF0FDF4);
  static const Color textColorPrimary = Color(0xFF0F172A);
  static const Color textColorSecondary = Color(0xFF64748B);
  String? _selectedSeverity;
  String _selectedStatusFilter = 'All'; // 'All', 'Pending', 'Fixed'

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bgColor,
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 10),
                _buildHeader(),
                const SizedBox(height: 25),
                const Text(
                  'Admin Dashboard',
                  style: TextStyle(
                    color: textColorPrimary,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Text(
                  'Real-time system overview',
                  style: TextStyle(color: textColorSecondary, fontSize: 16),
                ),
                const SizedBox(height: 25),
                _buildSummaryStats(),
                const SizedBox(height: 30),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      (_selectedSeverity == null || _selectedSeverity!.isEmpty)
                          ? 'Recent Reports'
                          : 'Recent ${_selectedSeverity![0].toUpperCase()}${_selectedSeverity!.length > 1 ? _selectedSeverity!.substring(1).toLowerCase() : ''} Reports',
                      style: const TextStyle(
                        color: textColorPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _selectedSeverity = null;
                        });
                      },
                      child: Text(
                        _selectedSeverity == null ? 'View all' : 'Clear filter',
                        style: const TextStyle(
                          color: primaryOrange,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ],
                ),
                _buildRecentReportsList(),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: _buildBottomNav(),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  colors: [primaryOrange, Color(0xFFD45D16)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                boxShadow: [
                  BoxShadow(
                    color: primaryOrange.withOpacity(0.3),
                    blurRadius: 10,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(Icons.send, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 12),
            const Text(
              'PotholeWatch',
              style: TextStyle(
                color: textColorPrimary,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        IconButton(
          onPressed: () {},
          icon: Icon(Icons.notifications, color: textColorSecondary),
          tooltip: 'Notifications',
        ),
      ],
    );
  }

  Widget _buildSummaryStats() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('potholes').snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: SelectableText(
              'Error loading stats: ${snapshot.error}\n${snapshot.stackTrace}',
              style: const TextStyle(color: Colors.red, fontSize: 10),
            ),
          );
        }
        int high = 0, med = 0, low = 0, fixedTotal = 0, pendingTotal = 0;
        if (snapshot.hasData) {
          for (var doc in snapshot.data!.docs) {
            final data = doc.data() as Map<String, dynamic>? ?? {};
            String sev = (data['severity'] ?? '').toString().toLowerCase();
            String status = (data['status'] ?? '').toString().toLowerCase();

            if (status == 'fixed') {
              fixedTotal++;
            } else {
              pendingTotal++;
            }

            if (sev == 'high') {
              high++;
            } else if (sev == 'medium' || sev == 'med')
              med++;
            else
              low++;
          }
        }

        return Column(
          children: [
            Row(
              children: [
                _buildStatCard('HIGH', high.toString(), bgHigh, textHigh, () {
                  setState(
                    () => _selectedSeverity = _selectedSeverity == 'HIGH'
                        ? null
                        : 'HIGH',
                  );
                }, _selectedSeverity == 'HIGH'),
                const SizedBox(width: 15),
                _buildStatCard(
                  'MEDIUM',
                  med.toString(),
                  bgMed,
                  textMed,
                  () {
                    setState(
                      () => _selectedSeverity = _selectedSeverity == 'MEDIUM'
                          ? null
                          : 'MEDIUM',
                    );
                  },
                  _selectedSeverity == 'MEDIUM',
                ),
                const SizedBox(width: 15),
                _buildStatCard('LOW', low.toString(), bgLow, textLow, () {
                  setState(
                    () => _selectedSeverity = _selectedSeverity == 'LOW'
                        ? null
                        : 'LOW',
                  );
                }, _selectedSeverity == 'LOW'),
              ],
            ),
            const SizedBox(height: 15),
            Row(
              children: [
                _buildStatCard(
                  'PENDING',
                  pendingTotal.toString(),
                  Colors.blue.withOpacity(0.05),
                  Colors.blue,
                  () {
                    setState(() => _selectedStatusFilter = 'Pending');
                  },
                  _selectedStatusFilter == 'Pending',
                ),
                const SizedBox(width: 15),
                _buildStatCard(
                  'FIXED',
                  fixedTotal.toString(),
                  Colors.green.withOpacity(0.05),
                  Colors.green,
                  () {
                    setState(() => _selectedStatusFilter = 'Fixed');
                  },
                  _selectedStatusFilter == 'Fixed',
                ),
                const SizedBox(width: 15),
                _buildStatCard(
                  'ALL',
                  (pendingTotal + fixedTotal).toString(),
                  Colors.grey.withOpacity(0.05),
                  Colors.grey,
                  () {
                    setState(() => _selectedStatusFilter = 'All');
                  },
                  _selectedStatusFilter == 'All',
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildStatCard(
    String label,
    String value,
    Color bgColor,
    Color textColor,
    VoidCallback onTap,
    bool isSelected,
  ) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 15),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isSelected ? textColor : textColor.withOpacity(0.1),
              width: isSelected ? 2 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: isSelected
                    ? textColor.withOpacity(0.2)
                    : textColor.withOpacity(0.05),
                blurRadius: isSelected ? 12 : 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: textColor,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                value,
                style: const TextStyle(
                  color: textColorPrimary,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRecentReportsList() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('potholes')
          .orderBy('timestamp', descending: true)
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: SelectableText(
                'Error: ${snapshot.error}\n\nStack Trace:\n${snapshot.stackTrace}',
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }

        var docs = snapshot.data!.docs;

        // Convert to objects
        var potholes = docs.map((doc) {
          final data = doc.data() as Map<String, dynamic>? ?? {};
          return Pothole.fromMap({...data, 'id': doc.id});
        }).toList();

        // Apply filters client-side
        if (_selectedSeverity != null) {
          String filter = _selectedSeverity!.toLowerCase();
          potholes = potholes.where((p) {
            String s = p.severity.toLowerCase();
            if (filter == 'medium' || filter == 'med') {
              return s == 'medium' || s == 'med';
            }
            return s == filter;
          }).toList();
        }

        if (_selectedStatusFilter != 'All') {
          String statusFilter = _selectedStatusFilter.toLowerCase();
          potholes = potholes.where((p) {
            String s = p.status.toLowerCase();
            if (statusFilter == 'fixed') return s == 'fixed';
            return s != 'fixed'; // Covers 'Pending' or anything else not fixed
          }).toList();
        }

        // Limit results
        int limit = _selectedSeverity == null && _selectedStatusFilter == 'All'
            ? 5
            : 20;
        var displayPotholes = potholes.take(limit).toList();

        if (displayPotholes.isEmpty) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Center(
              child: Text(
                'No matching reports found',
                style: TextStyle(color: textColorSecondary),
              ),
            ),
          );
        }

        return Column(
          children: displayPotholes.map((pothole) {
            return _buildReportItem(pothole);
          }).toList(),
        );
      },
    );
  }

  Widget _buildReportItem(Pothole pothole) {
    String title = pothole.description.isEmpty
        ? 'Pothole Report'
        : pothole.description;
    String subtitle = 'Recently reported';
    String severity = pothole.severity.toUpperCase();
    String? imageUrl = pothole.imageUrl;

    Color sevColor = textMed;
    Color sevBg = bgMed;
    if (severity == 'HIGH') {
      sevColor = textHigh;
      sevBg = bgHigh;
    } else if (severity == 'LOW') {
      sevColor = textLow;
      sevBg = bgLow;
    }

    return GestureDetector(
      onTap: () => _showPotholeDetail(context, pothole),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: cardBgColor,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: textColorPrimary.withOpacity(0.05)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.02),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: imageUrl != null && imageUrl.isNotEmpty
                  ? Image.network(
                      imageUrl,
                      width: 60,
                      height: 60,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => _emptyImage(),
                    )
                  : _emptyImage(),
            ),
            const SizedBox(width: 15),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: textColorPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: textColorSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: sevBg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                severity == 'MEDIUM' ? 'MED' : severity,
                style: TextStyle(
                  color: sevColor,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showPotholeDetail(BuildContext context, Pothole pothole) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(25)),
          ),
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Pothole Details',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: textColorPrimary,
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.pop(context),
                    icon: Icon(Icons.close, color: textColorSecondary),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              if (pothole.imageUrl != null)
                ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: Image.network(
                    pothole.imageUrl!,
                    height: 250,
                    width: double.infinity,
                    fit: BoxFit.cover,
                  ),
                ),
              const SizedBox(height: 20),
              Row(
                children: [
                  _buildDetailTag(
                    pothole.severity.toUpperCase(),
                    pothole.severity.toUpperCase() == 'HIGH'
                        ? textHigh
                        : pothole.severity.toUpperCase() == 'LOW'
                        ? textLow
                        : textMed,
                    pothole.severity.toUpperCase() == 'HIGH'
                        ? bgHigh
                        : pothole.severity.toUpperCase() == 'LOW'
                        ? bgLow
                        : bgMed,
                  ),
                  const SizedBox(width: 10),
                  _buildDetailTag(
                    pothole.status.toUpperCase(),
                    primaryOrange,
                    primaryOrange.withOpacity(0.1),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              const Text(
                'DESCRIPTION',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: textColorSecondary,
                  letterSpacing: 1.1,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                pothole.description.isEmpty
                    ? 'No description provided'
                    : pothole.description,
                style: const TextStyle(
                  fontSize: 16,
                  color: textColorPrimary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 30),
              if (pothole.status.toLowerCase() != 'fixed')
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 0,
                    ),
                    onPressed: () async {
                      await FirebaseFirestore.instance
                          .collection('potholes')
                          .doc(pothole.id.toString())
                          .update({'status': 'fixed'});
                      if (context.mounted) Navigator.pop(context);
                    },
                    child: const Text(
                      'Mark as Completed',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              if (pothole.status.toLowerCase() == 'fixed')
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      side: const BorderSide(color: Colors.green),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: () => Navigator.pop(context),
                    child: const Text(
                      'Completed',
                      style: TextStyle(
                        color: Colors.green,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }

  Widget _buildDetailTag(String label, Color textColor, Color bgColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: textColor,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _emptyImage() {
    return Container(
      width: 60,
      height: 60,
      color: textColorPrimary.withOpacity(0.05),
      child: Icon(Icons.image, color: textColorSecondary),
    );
  }

  Widget _buildBottomNav() {
    return Container(
      padding: const EdgeInsets.only(top: 10, bottom: 20),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, -5),
          ),
        ],
        border: Border(
          top: BorderSide(color: Colors.grey.shade200, width: 0.5),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _buildNavItem(Icons.dashboard, 'Dashboard', true, () {}),
          _buildNavItem(Icons.map_outlined, 'Map', false, () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => AdminMapPage(
                  initialSeverity: _selectedSeverity,
                  initialStatusFilter: _selectedStatusFilter,
                ),
              ),
            );
          }),
          _buildNavItem(Icons.logout, 'Logout', false, () {
            _showLogoutConfirmation(context);
          }),
        ],
      ),
    );
  }

  Widget _buildNavItem(
    IconData icon,
    String label,
    bool isActive,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: isActive ? primaryOrange : textColorSecondary),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: isActive ? primaryOrange : textColorSecondary,
              fontSize: 12,
              fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }

  void _showLogoutConfirmation(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          title: const Text(
            'Confirm Logout',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          content: const Text(
            'Are you sure you want to log out of the admin session?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'Cancel',
                style: TextStyle(color: textColorSecondary),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (context) => const LoginPage()),
                  (route) => false,
                );
              },
              child: const Text(
                'Logout',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
