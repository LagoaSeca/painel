import 'dart:async';

import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'features/flyer/data/models/flyer_model.dart';
import 'core/network/flyer_api_service.dart';
import 'features/flyer/presentation/widgets/video_player_widget.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint('Firebase Init Error: $e');
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'PromoIQ TV',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: Colors.black),
      home: const TvBootstrapPage(),
    );
  }
}

class TvBootstrapPage extends StatefulWidget {
  const TvBootstrapPage({super.key});

  @override
  State<TvBootstrapPage> createState() => _TvBootstrapPageState();
}

class _TvBootstrapPageState extends State<TvBootstrapPage> {
  String _baseUrl = '';

  bool _loading = true;
  String? _error;
  String? _pairingCode;
  FlyerApiService? _apiService;
  Timer? _pairingTimer;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
  const baseUrl = "https://processador-imagem-712380421019.europe-west1.run.app/";

  _baseUrl = baseUrl;

  try {
    final (savedDeviceId, savedPanelToken) =
        await FlyerApiService.readSavedAuth();

    if (savedDeviceId != null &&
        savedDeviceId.isNotEmpty &&
        savedPanelToken != null &&
        savedPanelToken.isNotEmpty) {
      _apiService = FlyerApiService(
        baseUrl: baseUrl,
        panelToken: savedPanelToken,
        deviceId: savedDeviceId,
      );

      final pairData = await _apiService!.checkIfPaired();
      if (pairData.$1 && pairData.$2 != null) {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => FlyerViewer(
              apiService: _apiService!,
              userId: pairData.$2!,
            ),
          ),
        );
        return;
      }
    }

    await _startRegistrationFlow();
  } catch (e) {
    setState(() {
      _loading = false;
      _error = 'Falha na inicialização da TV: $e';
    });
  }
}

  Future<void> _startRegistrationFlow() async {
    await FlyerApiService.clearSavedAuth();
    final registration = await FlyerApiService.registerDevice(baseUrl: _baseUrl);

    // Reinicializa imediatamente com o panel_token recebido no registro.
    _apiService = FlyerApiService(
      baseUrl: _baseUrl,
      panelToken: registration.panelToken,
      deviceId: registration.deviceId,
    );

    setState(() {
      _loading = false;
      _pairingCode = registration.pairingCode;
      _error = null;
    });

    _pairingTimer?.cancel();
    _pairingTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      try {
        final pairData = await _apiService!.checkIfPaired();
        if (pairData.$1 && pairData.$2 != null && mounted) {
          timer.cancel();
          Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => FlyerViewer(apiService: _apiService!, userId: pairData.$2!)),
          );
        }
      } catch (_) {
        // mantém polling de pareamento
      }
    });
  }

  @override
  void dispose() {
    _pairingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    if (_error != null) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 64),
                const SizedBox(height: 16),
                Text(_error!, textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(onPressed: _bootstrap, child: const Text('Tentar novamente')),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Código de pareamento', style: TextStyle(fontSize: 24)),
            const SizedBox(height: 20),
            Text(
              _pairingCode ?? '------',
              style: const TextStyle(fontSize: 72, letterSpacing: 12, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            const Text('Digite este código no app gerenciador para conectar esta TV.'),
            const SizedBox(height: 20),
            const CircularProgressIndicator(),
          ],
        ),
      ),
    );
  }
}

class FlyerViewer extends StatefulWidget {
  final FlyerApiService apiService;
  final String userId;

  const FlyerViewer({super.key, required this.apiService, required this.userId});

  @override
  State<FlyerViewer> createState() => _FlyerViewerState();
}

class _FlyerViewerState extends State<FlyerViewer> {
  Timer? _updateTimer;
  StreamSubscription? _updateSubscription;
  Timer? _slideshowTimer;
  Timer? _ticker;

  int _retryCount = 0;
  bool _isPolling = true;

  List<Flyer> _flyers = [];
  int _currentIndex = 0;
  bool _isLoading = true;
  String? _errorMessage;

  Flyer? get _currentFlyer =>
      _flyers.isNotEmpty ? _flyers[_currentIndex] : null;

  @override
  void initState() {
    super.initState();
    _initializeViewer();
  }

  Future<void> _initializeViewer() async {
    // 🔥 1. CARREGA CACHE PRIMEIRO
    final cached = await _loadFlyersLocally();
    if (cached.isNotEmpty) {
      setState(() {
        _flyers = cached;
        _isLoading = false;
        _errorMessage = "📡 Modo offline (cache)";
      });
      _startSlideshow();
    }

    // 🔥 2. TENTA BUSCAR ONLINE
    await _updateFlyersList();

    _setupPushListener();
    _startTicker();
  }

  void _startTicker() {
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted && (_currentFlyer?.timerEnabled ?? false)) {
        setState(() {});
      }
    });
  }

  // =========================
  // 🔥 CACHE LOCAL
  // =========================

  Future<void> _saveFlyersLocally(List<Flyer> flyers) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = flyers.map((f) => f.toJson()).toList();
    await prefs.setString('cached_flyers', jsonEncode(jsonList));
  }

  Future<List<Flyer>> _loadFlyersLocally() async {
    final prefs = await SharedPreferences.getInstance();
    final data = prefs.getString('cached_flyers');

    if (data == null) return [];

    final List decoded = jsonDecode(data);
    return decoded.map((e) => Flyer.fromJson(e)).toList();
  }

  // =========================
  // 🔥 FIREBASE / FALLBACK
  // =========================

  void _setupPushListener() {
    try {
      _updateSubscription = FirebaseFirestore.instance
          .collection('device_updates')
          .doc(widget.userId)
          .snapshots()
          .listen((snapshot) {
        if (snapshot.exists) {
          _updateFlyersList();
        }
      });
    } catch (e) {
      debugPrint('Firebase falhou, fallback para polling: $e');
      _scheduleNextUpdate();
    }
  }

  void _scheduleNextUpdate() {
    if (!_isPolling) return;

    const baseInterval = 30;
    const maxInterval = 300;

    final interval =
        (baseInterval * (1 << _retryCount)).clamp(0, maxInterval);

    _updateTimer =
        Timer(Duration(seconds: interval), _updateFlyersList);
  }

  // =========================
  // 🔥 SLIDESHOW
  // =========================

  void _startSlideshow() {
    _slideshowTimer?.cancel();

    if (_flyers.isEmpty || !_isPolling) return;

    final current = _currentFlyer;
    if (current == null) return;

    final duration = current.hasVideo
        ? const Duration(seconds: 15)
        : const Duration(seconds: 8);

    _slideshowTimer = Timer(duration, () {
      if (!mounted || !_isPolling) return;

      setState(() {
        _currentIndex = (_currentIndex + 1) % _flyers.length;
      });

      _startSlideshow();
    });
  }

  // =========================
  // 🔥 UPDATE COM OFFLINE
  // =========================

  Future<void> _updateFlyersList() async {
    if (!_isPolling) return;

    if (_flyers.isEmpty) {
      setState(() {
        _isLoading = true;
        _errorMessage = null;
      });
    }

    try {
      final fetched = await widget.apiService.fetchAllFlyers();

      _retryCount = 0;

      // 🔥 salva cache
      await _saveFlyersLocally(fetched);

      if (mounted) {
        setState(() {
          _flyers = fetched;
          _errorMessage = null;
          _isLoading = false;

          if (_currentIndex >= _flyers.length &&
              _flyers.isNotEmpty) {
            _currentIndex = 0;
          }
        });

        _startSlideshow();
      }
    } catch (e) {
      _retryCount = (_retryCount + 1).clamp(0, 5);

      final cached = await _loadFlyersLocally();

      if (mounted) {
        if (cached.isNotEmpty) {
          setState(() {
            _flyers = cached;
            _errorMessage =
                "📡 Sem internet - exibindo últimas promoções";
            _isLoading = false;
          });

          _startSlideshow();
        } else {
          setState(() {
            _errorMessage = e.toString();
            _isLoading = false;
          });
        }
      }
    } finally {
      if (_updateSubscription == null) {
        _scheduleNextUpdate();
      }
    }
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _updateSubscription?.cancel();
    _slideshowTimer?.cancel();
    _ticker?.cancel();
    _isPolling = false;
    super.dispose();
  }

  // =========================
  // 🎨 UI
  // =========================

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: _buildBody());
  }

  Widget _buildBody() {
    if (_isLoading && _currentFlyer == null) {
      return _buildMessageState(
        icon: Icons.downloading,
        title: 'Conectando ao servidor...',
        isProgress: true,
      );
    }

    if (_errorMessage != null && _currentFlyer == null) {
      return _buildMessageState(
        icon: Icons.error_outline,
        title: 'Erro de conexão',
        message: _errorMessage!,
        onRetry: _initializeViewer,
      );
    }

    if (_currentFlyer == null) {
      return _buildMessageState(
        icon: Icons.image_not_supported_outlined,
        title: 'Nenhum flyer ativo',
        message: 'Aguardando publicação...',
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final flyer = _currentFlyer!;

        return Stack(
          alignment: Alignment.center,
          children: [
            flyer.hasVideo
          ? _buildVideoWidget(constraints)
          : AnimatedSwitcher(
              duration: const Duration(milliseconds: 700),
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: _buildImageWidget(constraints),
            ),

            // 🔥 TIMER (mantido)
            if (flyer.timerEnabled)
              _buildTimerOverlay(flyer, constraints),

            // 🔥 BANNER OFFLINE
            if (_errorMessage != null)
              Positioned(
                top: 20,
                left: 20,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  color: Colors.black54,
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  String _getFullUrl(String url) {
    if (url.startsWith('http')) return url;

    final base = widget.apiService.baseUrl.endsWith('/')
        ? widget.apiService.baseUrl.substring(
            0, widget.apiService.baseUrl.length - 1)
        : widget.apiService.baseUrl;

    return url.startsWith('/')
        ? '$base$url'
        : '$base/$url';
  }

  // 🔥 CACHE DE IMAGEM REAL

  Widget _buildImageWidget(BoxConstraints constraints) {
    final imageUrl = _getFullUrl(_currentFlyer!.thumbnailUrl);

    return CachedNetworkImage(
      key: ValueKey(_currentFlyer!.id),
      imageUrl: imageUrl,
      fit: BoxFit.contain,
      width: constraints.maxWidth,
      height: constraints.maxHeight,
      placeholder: (_, __) =>
          const Center(child: CircularProgressIndicator()),
      errorWidget: (_, __, ___) =>
          const Icon(Icons.error),
    );
  }

  Widget _buildVideoWidget(BoxConstraints constraints) {
    final videoUrl = _getFullUrl(_currentFlyer!.videoUrl!);

    return SizedBox(
      width: constraints.maxWidth,
      height: constraints.maxHeight,
      child: VideoPlayerWidget(
        key: ValueKey(_currentFlyer!.id),
        videoUrl: videoUrl,
        showControls: false,
      ),
    );
  }

  Widget _buildMessageState({
    required IconData icon,
    required String title,
    String? message,
    bool isProgress = false,
    VoidCallback? onRetry,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (isProgress)
              const CircularProgressIndicator()
            else
              Icon(icon, size: 64, color: Colors.grey.shade700),
            const SizedBox(height: 24),
            Text(title,
                style: Theme.of(context).textTheme.headlineSmall),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message, textAlign: TextAlign.center),
            ],
            if (onRetry != null) ...[
              const SizedBox(height: 24),
              ElevatedButton.icon(
                icon: const Icon(Icons.refresh),
                label: const Text('Tentar novamente'),
                onPressed: onRetry,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

  Widget _buildTimerOverlay(Flyer flyer, BoxConstraints constraints) {
    if (flyer.timerTargetTime == null) return const SizedBox.shrink();

    final diff = flyer.timerTargetTime!.difference(DateTime.now());
    if (diff.isNegative) return const SizedBox.shrink();

    // Ratio para converter coordenadas do preview (392px) para a TV
    final double ratioX = constraints.maxWidth / 392.0;
    final double ratioY = constraints.maxHeight / 392.0;
    
    // Escala base do sticker na TV
    final double scaleFactor = (constraints.maxWidth / 1080.0).clamp(0.5, 2.5);

    final h = diff.inHours.toString().padLeft(2, '0');
    final m = (diff.inMinutes % 60).toString().padLeft(2, '0');
    final s = (diff.inSeconds % 60).toString().padLeft(2, '0');

    return Positioned(
      left: flyer.timerPosX * ratioX,
      top: flyer.timerPosY * ratioY,
      child: Transform.scale(
        scale: scaleFactor * 2.2,
        alignment: Alignment.topLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Colors.redAccent, Color(0xFFD32F2F)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white, width: 2.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.5),
                blurRadius: 12,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.timer, color: Colors.white, size: 20),
              const SizedBox(width: 8),
              Text(
                'TERMINA EM: $h:$m:$s',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                  shadows: [Shadow(color: Colors.black45, blurRadius: 4, offset: Offset(1, 1))],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

