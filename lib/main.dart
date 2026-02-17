import 'dart:async';
import 'package:ai_barcode_scanner/ai_barcode_scanner.dart';
import 'package:excel/excel.dart';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
// import 'package:simple_barcode_scanner/simple_barcode_scanner.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const BarcodeScannerApp());
}

/* ---------------- APP ---------------- */
class BarcodeScannerApp extends StatelessWidget {
  const BarcodeScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'QR Scanner',
      theme: ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          surface: Colors.black,
          primary: Colors.white,
          onPrimary: Colors.black,
          onSurface: Colors.white,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.black,
          elevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
          ),
          iconTheme: IconThemeData(color: Colors.white),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          shape: CircleBorder(),
        ),
        cardTheme: CardThemeData(
          color: Color(0xFF0E0E0E),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        snackBarTheme: const SnackBarThemeData(
          backgroundColor: Color(0xFF1A1A1A),
          contentTextStyle: TextStyle(color: Colors.white),
        ),
      ),
      home: const HomePage(),
    );
  }
}

/* ---------------- HOME PAGE ---------------- */
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String _todayKey() {
    return DateFormat('yyyy-MM-dd').format(DateTime.now());
  }

  late String _selectedDateKey;

  final int _limit = 15;
  DocumentSnapshot? _lastDoc;
  bool _isLoading = false;
  bool _hasMore = true;
  final List<DocumentSnapshot> _docs = [];
  final ScrollController _scrollController = ScrollController();
  bool _initialLoading = true;
  StreamSubscription<QuerySnapshot>? _subscription;
  bool _processingScan = false;
  bool _busy = false;

  Future<void> _incrementDateCounter(String dateKey) async {
    final ref = _firestore.collection('scans_by_date').doc(dateKey);

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final count = (snap.data()?['count'] ?? 0) as int;

      tx.set(ref, {'count': count + 1}, SetOptions(merge: true));
    });
  }

  Future<void> _decrementDateCounter(String dateKey) async {
    final ref = _firestore.collection('scans_by_date').doc(dateKey);

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final count = (snap.data()?['count'] ?? 0) as int;

      tx.set(ref, {
        'count': count > 0 ? count - 1 : 0,
      }, SetOptions(merge: true));
    });
  }

  Future<void> _incrementTotalCounter() async {
    final ref = _firestore.collection('metadata').doc('stats');

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final total = (snap.data()?['totalCount'] ?? 0) as int;

      tx.set(ref, {'totalCount': total + 1}, SetOptions(merge: true));
    });
  }

  Future<void> _decrementTotalCounter() async {
    final ref = _firestore.collection('metadata').doc('stats');

    await _firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final total = (snap.data()?['totalCount'] ?? 0) as int;

      tx.set(ref, {
        'totalCount': total > 0 ? total - 1 : 0,
      }, SetOptions(merge: true));
    });
  }

  Future<void> _saveScan(String code) async {
    try {
      if (mounted) setState(() => _busy = true);
      final dateKey = _selectedDateKey;

      final existing = await _firestore
          .collection('scans_by_date')
          .doc(dateKey)
          .collection('scans')
          .where('code', isEqualTo: code)
          .limit(1)
          .get();

      if (existing.docs.isNotEmpty) {
        if (!mounted) return;
        if (mounted) setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Already scanned for this date')),
        );
        return;
      }

      DocumentReference<Map<String, dynamic>> docRef = await _firestore
          .collection('scans_by_date')
          .doc(dateKey)
          .collection('scans')
          .add({'code': code, 'timestamp': FieldValue.serverTimestamp()});

      if (!mounted) return;
      if (docRef.id.isEmpty) {
        throw Exception('Failed to save scan');
      }

      await _incrementDateCounter(dateKey);
      await _incrementTotalCounter();

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Scan saved'),
          duration: Duration(seconds: 2),
        ),
      );
      if (mounted) setState(() => _busy = false);
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  Future<void> _editName(String code) async {
    final controller = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Assign Name'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Enter name (optional)'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              final name = controller.text.trim();

              await _firestore.collection('labels').doc(code).set({
                'name': name,
              }, SetOptions(merge: true));

              if (mounted) Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  String _formatTimestamp(Timestamp? ts) {
    if (ts == null) return 'Saving...';
    return DateFormat('MMM dd, yyyy • HH:mm:ss').format(ts.toDate());
  }

  Future<void> _handleDetect(BarcodeCapture capture) async {
    if (_processingScan) return;

    final code = capture.barcodes.first.rawValue;
    if (code == null || code.isEmpty) return;

    _processingScan = false;

    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }

    await _saveScan(code);
  }

  Future<void> _openScanner() async {
    // Navigator.push(
    //   context,
    //   MaterialPageRoute(
    //     builder: (_) => ScannerPage(
    //       onScanned: (code) {
    //         _saveScan(code);
    //         Navigator.pop(context);
    //       },
    //     ),
    //   ),
    // );
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AiBarcodeScanner(onDetect: _handleDetect),
      ),
    );
    _processingScan = false; // keep state clean after returning from scanner
    // _saveScan(Random().nextInt(1000000000).toString());
  }

  @override
  void initState() {
    super.initState();
    _selectedDateKey = _todayKey();
    _listenInitial();
    _scrollController.addListener(() {
      if (_scrollController.position.pixels >=
              _scrollController.position.maxScrollExtent - 200 &&
          !_isLoading &&
          _hasMore) {
        _loadMore();
      }
    });
  }

  Future<void> _pickDate() async {
    DateTime initial;
    try {
      initial = DateTime.parse(_selectedDateKey);
    } catch (_) {
      initial = DateTime.now();
    }

    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
    );

    if (picked == null) return;

    final newKey = DateFormat('yyyy-MM-dd').format(picked);

    if (newKey == _selectedDateKey) return;

    _subscription?.cancel();

    setState(() {
      _docs.clear();
      _lastDoc = null;
      _hasMore = true;
      _isLoading = false;
      _initialLoading = true;
      _selectedDateKey = newKey;
    });

    _listenInitial();
  }

  void _listenInitial() {
    _subscription = _firestore
        .collection('scans_by_date')
        .doc(_selectedDateKey)
        .collection('scans')
        .orderBy('timestamp', descending: true)
        .limit(_limit)
        .snapshots()
        .listen((snapshot) {
          _docs.clear();
          _docs.addAll(snapshot.docs);

          if (snapshot.docs.isNotEmpty) {
            _lastDoc = snapshot.docs.last;
          }

          _initialLoading = false;
          if (mounted) setState(() {});
        });
  }

  Future<void> _loadInitial() async {
    final snapshot = await _firestore
        .collection('scans_by_date')
        .doc(_selectedDateKey)
        .collection('scans')
        .orderBy('timestamp', descending: true)
        .limit(_limit)
        .get();

    if (snapshot.docs.isNotEmpty) {
      _lastDoc = snapshot.docs.last;
      _docs.addAll(snapshot.docs);
    }

    if (snapshot.docs.length < _limit) {
      _hasMore = false;
    }

    if (mounted) setState(() {});
  }

  Future<void> _loadMore() async {
    _isLoading = true;

    final snapshot = await _firestore
        .collection('scans_by_date')
        .doc(_selectedDateKey)
        .collection('scans')
        .orderBy('timestamp', descending: true)
        .startAfterDocument(_lastDoc!)
        .limit(_limit)
        .get();

    if (snapshot.docs.isNotEmpty) {
      _lastDoc = snapshot.docs.last;
      _docs.addAll(snapshot.docs);
    }

    if (snapshot.docs.length < _limit) {
      _hasMore = false;
    }

    _isLoading = false;
    if (mounted) setState(() {});
  }

  Future<void> _exportToExcel() async {
    try {
      if (mounted) setState(() => _busy = true);
      final snapshot = await _firestore
          .collection('scans')
          .orderBy('timestamp', descending: true)
          .get();

      final excel = Excel.createExcel();
      final sheet = excel['Scans'];

      sheet.appendRow(['Code', 'Timestamp']);

      for (final doc in snapshot.docs) {
        final data = doc.data();
        final ts = data['timestamp'] as Timestamp?;

        sheet.appendRow([
          data['code'] ?? '',
          ts != null ? _formatTimestamp(ts) : '',
        ]);
      }

      final dir = Directory('/storage/emulated/0/Download');
      final file = File('${dir.path}/scans.xlsx');
      final bytes = excel.encode();

      if (bytes != null) {
        await file.writeAsBytes(bytes);
      }

      if (!mounted) return;
      if (mounted) setState(() => _busy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Excel exported: ${file.path}')));
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
    }
  }

  Future<void> _deleteAllScans() async {
    try {
      if (mounted) setState(() => _busy = true);
      final dateRef = _firestore
          .collection('scans_by_date')
          .doc(_selectedDateKey);

      final scansSnapshot = await dateRef.collection('scans').get();

      final docs = scansSnapshot.docs;
      for (int i = 0; i < docs.length; i += 400) {
        final batch = _firestore.batch();
        final chunk = docs.skip(i).take(400);

        for (final scanDoc in chunk) {
          batch.delete(scanDoc.reference);
        }

        await batch.commit();
      }

      await dateRef.delete();

      final counterRef = _firestore.collection('metadata').doc('stats');

      await _firestore.runTransaction((tx) async {
        final snapshot = await tx.get(counterRef);
        final total = (snapshot.data()?['totalCount'] ?? 0) as int;

        tx.set(counterRef, {
          'todayCount': 0,
          'totalCount': total >= docs.length ? total - docs.length : 0,
        }, SetOptions(merge: true));
      });

      if (!mounted) return;
      setState(() {
        _docs.clear();
        _hasMore = false;
      });
      if (mounted) setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Selected date scans deleted')),
      );

      await _firestore.collection('scans_by_date').doc(_selectedDateKey).set({
        'count': 0,
      }, SetOptions(merge: true));
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
    }
  }

  Future<void> _confirmDeleteAll() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete All Scans'),
        content: const Text(
          'This action cannot be undone. Do you want to continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _deleteAllScans();
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Saifee Fatemi Counter'),
        actions: [
          StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
            stream: _firestore
                .collection('scans_by_date')
                .doc(_selectedDateKey)
                .snapshots(),
            builder: (context, snapshot) {
              final count = snapshot.data?.data()?['count'] ?? 0;

              return FutureBuilder<DocumentSnapshot<Map<String, dynamic>>>(
                future: _firestore.collection('metadata').doc('stats').get(),
                builder: (context, statsSnap) {
                  final total = statsSnap.data?.data()?['totalCount'] ?? 0;

                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Center(
                      child: Text(
                        '${_selectedDateKey == _todayKey() ? 'Today' : DateFormat('dd/MM').format(DateTime.parse(_selectedDateKey))}: $count  |  Total: $total',
                      ),
                    ),
                  );
                },
              );
            },
          ),
          PopupMenuButton<String>(
            onSelected: (value) async {
              if (value == 'export') _exportToExcel();
              if (value == 'date') _pickDate();
              if (value == 'delete') _confirmDeleteAll();
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: 'export', child: Text('Export to Excel')),
              PopupMenuItem(value: 'date', child: Text('Select Date')),
              PopupMenuItem(value: 'delete', child: Text('Delete All Scans')),
            ],
          ),
        ],
      ),
      body: Stack(
        children: [
          _initialLoading
              ? const Center(child: CircularProgressIndicator())
              : _docs.isEmpty
              ? const Center(
                  child: Text(
                    'No scans yet',
                    style: TextStyle(color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  controller: _scrollController,
                  itemCount: _docs.length + (_isLoading ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index >= _docs.length) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }

                    final data = _docs[index].data() as Map<String, dynamic>;

                    return Card(
                      margin: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      child: ListTile(
                        leading: const Icon(Icons.qr_code_2),
                        onTap: () {
                          _editName(data['code']);
                        },
                        title:
                            StreamBuilder<
                              DocumentSnapshot<Map<String, dynamic>>
                            >(
                              stream: _firestore
                                  .collection('labels')
                                  .doc(data['code'])
                                  .snapshots(),
                              builder: (context, snapshot) {
                                final name = snapshot.data?.data()?['name'];
                                final display =
                                    (name != null && name.toString().isNotEmpty)
                                    ? name
                                    : (data['code'] ?? 'Unknown');

                                return Text(
                                  display.toString(),
                                  style: const TextStyle(letterSpacing: 0.3),
                                );
                              },
                            ),
                        subtitle: Text(
                          _formatTimestamp(data['timestamp']),
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 12,
                          ),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.close, color: Colors.grey),
                          onPressed: () async {
                            final doc = _docs[index];
                            await doc.reference.delete();
                            await _decrementDateCounter(_selectedDateKey);
                            await _decrementTotalCounter();
                            _docs.removeWhere((d) => d.id == doc.id);
                            if (mounted) setState(() {});
                          },
                        ),
                      ),
                    );
                  },
                ),

          if (_busy)
            Container(
              color: Colors.black54,
              child: const Center(child: CircularProgressIndicator()),
            ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _openScanner,
        child: RotatedBox(
          quarterTurns: 1,
          child: const Icon(Icons.document_scanner_outlined),
        ),
      ),
    );
  }
}
