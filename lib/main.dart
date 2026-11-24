import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  await VoidAudioEngine.instance.init();
  runApp(const SchulteApp());
}

// -------------------------------------------------------------
// 0. 纯代码实时合成音效引擎（轻触 + 机械滴答 + 五声音阶共鸣）
// -------------------------------------------------------------
class VoidAudioEngine {
  VoidAudioEngine._();
  static final VoidAudioEngine instance = VoidAudioEngine._();

  final List<AudioPlayer> _sfxPool = List.generate(4, (_) => AudioPlayer());
  int _poolIndex = 0;
  bool _isMuted = false;
  bool get isMuted => _isMuted;

  late final Uint8List _tapWav;
  late final Uint8List _tickWav;
  late final Uint8List _urgentTickWav;
  late final Uint8List _successWav;
  late final Uint8List _errorWav;
  late final List<Uint8List> _scaleWavs;

  Future<void> init() async {
    // 1. 界面轻触音效
    _tapWav = _synthesizeWav(
      durationSec: 0.11,
      sampleGen: (t, dur) {
        final env = exp(-t * 38) * (t < 0.004 ? t / 0.004 : 1.0);
        return (0.7 * sin(2 * pi * 880 * t) + 0.3 * sin(2 * pi * 1760 * t)) * env * 0.45;
      },
    );

    // 2. 机械时钟滴答声
    _tickWav = _synthesizeWav(
      durationSec: 0.045,
      sampleGen: (t, dur) {
        final env = exp(-t * 110) * (t < 0.002 ? t / 0.002 : 1.0);
        return (0.6 * sin(2 * pi * 1650 * t) + 0.4 * sin(2 * pi * 3100 * t)) * env * 0.55;
      },
    );

    // 3. 最后 5 秒急促高音滴答
    _urgentTickWav = _synthesizeWav(
      durationSec: 0.055,
      sampleGen: (t, dur) {
        final env = exp(-t * 90) * (t < 0.002 ? t / 0.002 : 1.0);
        return (0.6 * sin(2 * pi * 2200 * t) + 0.4 * sin(2 * pi * 3800 * t)) * env * 0.65;
      },
    );

    // 4. 成功/过关和弦音
    _successWav = _synthesizeWav(
      durationSec: 0.36,
      sampleGen: (t, dur) {
        final env = exp(-t * 9) * (t < 0.008 ? t / 0.008 : 1.0);
        final n1 = sin(2 * pi * 587.33 * t);
        final n2 = t > 0.06 ? sin(2 * pi * 880.0 * (t - 0.06)) : 0.0;
        final n3 = t > 0.12 ? sin(2 * pi * 1174.66 * (t - 0.12)) : 0.0;
        return (n1 * 0.4 + n2 * 0.35 + n3 * 0.35) * env * 0.5;
      },
    );

    // 5. 失误低沉震荡音
    _errorWav = _synthesizeWav(
      durationSec: 0.28,
      sampleGen: (t, dur) {
        final env = exp(-t * 14) * (t < 0.005 ? t / 0.005 : 1.0);
        return (0.65 * sin(2 * pi * 130.8 * t) + 0.45 * sin(2 * pi * 138.6 * t)) * env * 0.65;
      },
    );

    // 6. 铭刻 9 阶递进五声音阶
    const freqs = [587.33, 659.25, 783.99, 880.00, 1046.50, 1174.66, 1318.51, 1567.98, 1760.00];
    _scaleWavs = freqs.map((f) {
      return _synthesizeWav(
        durationSec: 0.24,
        sampleGen: (t, dur) {
          final env = exp(-t * 16) * (t < 0.005 ? t / 0.005 : 1.0);
          return (0.75 * sin(2 * pi * f * t) + 0.25 * sin(2 * pi * f * 2 * t)) * env * 0.5;
        },
      );
    }).toList();
  }

  Future<void> toggleMute() async {
    _isMuted = !_isMuted;
    if (!_isMuted) playTap();
  }

  void _playSfx(Uint8List bytes) {
    if (_isMuted) return;
    final player = _sfxPool[_poolIndex];
    _poolIndex = (_poolIndex + 1) % _sfxPool.length;
    player.play(BytesSource(bytes));
  }

  void playTap() => _playSfx(_tapWav);
  void playTick({bool urgent = false}) => _playSfx(urgent ? _urgentTickWav : _tickWav);
  void playSuccess() => _playSfx(_successWav);
  void playError() => _playSfx(_errorWav);
  void playScaleStep(int stepIndex) =>
      _playSfx(_scaleWavs[stepIndex.clamp(0, _scaleWavs.length - 1)]);

  Uint8List _synthesizeWav({
    required double durationSec,
    required double Function(double t, double duration) sampleGen,
  }) {
    const int sampleRate = 22050;
    final int numSamples = (sampleRate * durationSec).round();
    final int dataSize = numSamples * 2;
    final ByteData buffer = ByteData(44 + dataSize);

    void writeStr(int offset, String s) {
      for (int i = 0; i < s.length; i++) {
        buffer.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    writeStr(0, 'RIFF');
    buffer.setUint32(4, 36 + dataSize, Endian.little);
    writeStr(8, 'WAVE');
    writeStr(12, 'fmt ');
    buffer.setUint32(16, 16, Endian.little);
    buffer.setUint16(20, 1, Endian.little);
    buffer.setUint16(22, 1, Endian.little);
    buffer.setUint32(24, sampleRate, Endian.little);
    buffer.setUint32(28, sampleRate * 2, Endian.little);
    buffer.setUint16(32, 2, Endian.little);
    buffer.setUint16(34, 16, Endian.little);
    writeStr(36, 'data');
    buffer.setUint32(40, dataSize, Endian.little);

    for (int i = 0; i < numSamples; i++) {
      final double t = i / sampleRate;
      final double val = sampleGen(t, durationSec).clamp(-1.0, 1.0);
      buffer.setInt16(44 + i * 2, (val * 32767).round(), Endian.little);
    }
    return buffer.buffer.asUint8List();
  }
}

class SchulteApp extends StatelessWidget {
  const SchulteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mind Sanctum',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(scaffoldBackgroundColor: Colors.transparent),
      home: const MainMenuScreen(),
    );
  }
}

// -------------------------------------------------------------
// 1. 通用视觉组件：虚空粒子背景、游戏外壳、统一弹窗
// -------------------------------------------------------------
class VoidBackground extends StatefulWidget {
  final Widget child;
  const VoidBackground({super.key, required this.child});

  @override
  State<VoidBackground> createState() => _VoidBackgroundState();
}

class _VoidBackgroundState extends State<VoidBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  final _rng = Random();
  late final List<List<double>> _particles;

  @override
  void initState() {
    super.initState();
    _particles = List.generate(28, (_) => [
      _rng.nextDouble(),
      _rng.nextDouble(),
      0.8 + _rng.nextDouble() * 1.8,
      0.0003 + _rng.nextDouble() * 0.0007,
      0.2 + _rng.nextDouble() * 0.5,
      _rng.nextDouble() * 2 * pi,
    ]);
    _ctrl = AnimationController(vsync: this, duration: const Duration(seconds: 10))
      ..addListener(() {
        for (var p in _particles) {
          p[1] -= p[3];
          if (p[1] < -0.05) {
            p[1] = 1.05;
            p[0] = _rng.nextDouble();
          }
        }
      })
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0.0, -0.1),
              radius: 1.1,
              colors: [Color(0xFF131A28), Color(0xFF090D14), Color(0xFF05070A)],
              stops: [0.0, 0.65, 1.0],
            ),
          ),
        ),
        AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) => CustomPaint(
            size: Size.infinite,
            painter: _ParticlePainter(_particles, _ctrl.value * 2 * pi),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _ParticlePainter extends CustomPainter {
  final List<List<double>> particles;
  final double time;
  _ParticlePainter(this.particles, this.time);

  @override
  void paint(Canvas canvas, Size size) {
    for (var p in particles) {
      final op = (p[4] * (0.6 + 0.4 * sin(time + p[5]))).clamp(0.05, 0.9);
      final center = Offset(p[0] * size.width, p[1] * size.height);
      canvas.drawCircle(center, p[2] * 1.8,
          Paint()..color = const Color(0xFF64D2FF).withOpacity(op * 0.25));
      canvas.drawCircle(center, p[2],
          Paint()..color = const Color(0xFF64D2FF).withOpacity(op));
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter oldDelegate) => true;
}

class GameScaffold extends StatelessWidget {
  final bool canPop;
  final VoidCallback onExit;
  final Widget? centerBadge;
  final Widget rightBadge;
  final String subtitle;
  final Widget body;
  final String footer;

  const GameScaffold({
    super.key,
    required this.canPop,
    required this.onExit,
    this.centerBadge,
    required this.rightBadge,
    required this.subtitle,
    required this.body,
    required this.footer,
  });

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, _) {},
      child: Scaffold(
        body: VoidBackground(
          child: SafeArea(
            child: Column(
              children: [
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back_ios_new,
                            color: Color(0xFF8F9CAE), size: 18),
                        onPressed: () {
                          VoidAudioEngine.instance.playTap();
                          onExit();
                        },
                      ),
                      if (centerBadge != null) centerBadge!,
                      rightBadge,
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  subtitle,
                  style: const TextStyle(
                      color: Color(0xFF8F9CAE), fontSize: 12, letterSpacing: 2),
                ),
                const Spacer(),
                body,
                const Spacer(),
                Text(
                  footer,
                  style: const TextStyle(
                      color: Color(0xFF4A586E), fontSize: 11, letterSpacing: 1.5),
                ),
                const SizedBox(height: 28),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

void showHollowDialog({
  required BuildContext context,
  required String title,
  required Color accentColor,
  required Widget content,
  required List<Widget> actions,
}) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF131822),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFF2E3D52), width: 1),
      ),
      title: Center(
        child: Text(
          title,
          style: TextStyle(
            color: accentColor,
            fontSize: 17,
            letterSpacing: 3,
            shadows: [Shadow(color: accentColor, blurRadius: 8)],
          ),
        ),
      ),
      content: content,
      actions: actions,
    ),
  );
}

// -------------------------------------------------------------
// 2. 殿堂主页（三游戏横向滑动 + 全局音效开关）
// -------------------------------------------------------------
class MainMenuScreen extends StatefulWidget {
  const MainMenuScreen({super.key});

  @override
  State<MainMenuScreen> createState() => _MainMenuScreenState();
}

class _MainMenuScreenState extends State<MainMenuScreen>
    with TickerProviderStateMixin {
  final _pageController = PageController();
  int _currentPage = 0;

  late final AnimationController _discRotCtrl;
  late final AnimationController _stroopBreathCtrl;
  late final AnimationController _memoryPulseCtrl;

  // 轮盘设定
  int _ringCount = 3;
  int _maxNumber = 60;
  int _discTime = 60;

  // 幻色设定
  int _stroopTime = 45;

  // 铭刻设定
  int _memoryMode = 0;       // 0: 标准正序, 1: 镜像倒序, 2: 无尽突变
  int _memoryDifficulty = 0; // 0: 舒缓, 1: 均衡, 2: 严苛
  int _memoryStepConfig = 2; // 2: 自动递增, 3~9: 恒定格数

  @override
  void initState() {
    super.initState();
    _discRotCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 40))..repeat();
    _stroopBreathCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat(reverse: true);
    _memoryPulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 3))..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pageController.dispose();
    _discRotCtrl.dispose();
    _stroopBreathCtrl.dispose();
    _memoryPulseCtrl.dispose();
    super.dispose();
  }

  void _showConfigSheet({
    required Color accent,
    required Color btnBg,
    required String actionLabel,
    required Widget Function(StateSetter setModalState) contentBuilder,
    required VoidCallback onStart,
  }) {
    VoidAudioEngine.instance.playTap();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF10151F),
      barrierColor: Colors.black.withOpacity(0.75),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        side: BorderSide(color: Color(0xFF263242), width: 1),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 36,
                height: 3,
                decoration: BoxDecoration(
                  color: const Color(0xFF384456),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                '设定',
                style: TextStyle(
                  color: accent,
                  fontSize: 16,
                  letterSpacing: 4,
                  shadows: [Shadow(color: accent, blurRadius: 10)],
                ),
              ),
              const SizedBox(height: 20),
              contentBuilder(setModalState),
              const SizedBox(height: 22),
              GestureDetector(
                onTap: () {
                  VoidAudioEngine.instance.playTap();
                  Navigator.pop(ctx);
                  onStart();
                },
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: btnBg,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: accent, width: 1),
                    boxShadow: [BoxShadow(color: accent.withOpacity(0.18), blurRadius: 16)],
                  ),
                  child: Center(
                    child: Text(
                      actionLabel,
                      style: TextStyle(
                        color: const Color(0xFFE2E8F0),
                        letterSpacing: 4,
                        fontSize: 15,
                        shadows: [Shadow(color: accent, blurRadius: 8)],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSlider(String label, String valStr, double val, double min, double max,
      int div, Color color, ValueChanged<double> onChanged) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: Color(0xFF8F9CAE), fontSize: 13)),
            Text(valStr,
                style: TextStyle(
                    color: const Color(0xFFCBD5E1),
                    fontSize: 13,
                    fontFamily: 'monospace',
                    shadows: [Shadow(color: color, blurRadius: 4)])),
          ],
        ),
        Slider(
          value: val,
          min: min,
          max: max,
          divisions: div,
          activeColor: color,
          inactiveColor: const Color(0xFF222C3A),
          onChanged: onChanged,
        ),
      ],
    );
  }

  void _openDiscConfig() {
    const accent = Color(0xFF64D2FF);
    _showConfigSheet(
      accent: accent,
      btnBg: const Color(0xFF161F2C),
      actionLabel: '开启凝视',
      contentBuilder: (setModal) => Column(
        children: [
          _buildSlider('圆盘圈数', '$_ringCount 圈', _ringCount.toDouble(), 2, 5, 3, accent, (v) {
            setModal(() => _ringCount = v.round());
            setState(() => _ringCount = v.round());
          }),
          _buildSlider('数字上限', '1 ~ $_maxNumber', _maxNumber.toDouble(), 20, 100, 8, accent, (v) {
            setModal(() => _maxNumber = v.round());
            setState(() => _maxNumber = v.round());
          }),
          _buildSlider('限定时间', '$_discTime 秒', _discTime.toDouble(), 15, 120, 7, accent, (v) {
            setModal(() => _discTime = v.round());
            setState(() => _discTime = v.round());
          }),
        ],
      ),
      onStart: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SchulteWheelGameScreen(
            ringCount: _ringCount,
            maxNumber: _maxNumber,
            timeLimit: _discTime,
          ),
        ),
      ),
    );
  }

  void _openStroopConfig() {
    const accent = Color(0xFF4ECCA3);
    _showConfigSheet(
      accent: accent,
      btnBg: const Color(0xFF122320),
      actionLabel: '开启破幻',
      contentBuilder: (setModal) => _buildSlider(
        '试炼时限',
        '$_stroopTime 秒',
        _stroopTime.toDouble(),
        15,
        90,
        5,
        accent,
        (v) {
          setModal(() => _stroopTime = v.round());
          setState(() => _stroopTime = v.round());
        },
      ),
      onStart: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => StroopGameScreen(timeLimit: _stroopTime)),
      ),
    );
  }

  void _openMemoryConfig() {
    const accent = Color(0xFFFFB74D);
    final modes = ['标准正序', '镜像倒序', '无尽突变'];
    final diffs = ['舒缓', '均衡', '严苛'];
    final diffDescs = [
      '慢速闪烁 (900ms)，每 3 轮+1格，每 4 轮扩张棋盘',
      '适中节奏 (750ms)，每 2 轮+1格，每 3 轮扩张棋盘',
      '疾速闪现 (560ms)，每 1 轮+1格，每 2 轮扩张棋盘',
    ];

    _showConfigSheet(
      accent: accent,
      btnBg: const Color(0xFF221A10),
      actionLabel: '唤醒铭刻',
      contentBuilder: (setModal) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('试炼模式', style: TextStyle(color: Color(0xFF8F9CAE), fontSize: 12)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(modes.length, (idx) {
              final sel = _memoryMode == idx;
              return GestureDetector(
                onTap: () {
                  VoidAudioEngine.instance.playTap();
                  setModal(() => _memoryMode = idx);
                  setState(() => _memoryMode = idx);
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: sel ? const Color(0xFF261E14) : const Color(0xFF141A24),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: sel ? accent : const Color(0xFF2E384D)),
                  ),
                  child: Text(
                    modes[idx],
                    style: TextStyle(
                      color: sel ? accent : const Color(0xFF8F9CAE),
                      fontSize: 12,
                    ),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 18),
          const Text('难度曲线', style: TextStyle(color: Color(0xFF8F9CAE), fontSize: 12)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: List.generate(diffs.length, (idx) {
              final sel = _memoryDifficulty == idx;
              return Expanded(
                child: GestureDetector(
                  onTap: () {
                    VoidAudioEngine.instance.playTap();
                    setModal(() => _memoryDifficulty = idx);
                    setState(() => _memoryDifficulty = idx);
                  },
                  child: Container(
                    margin: EdgeInsets.symmetric(horizontal: idx == 1 ? 8 : 0),
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: sel ? const Color(0xFF261E14) : const Color(0xFF141A24),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: sel ? accent : const Color(0xFF2E384D)),
                    ),
                    child: Text(
                      diffs[idx],
                      style: TextStyle(
                        color: sel ? accent : const Color(0xFF8F9CAE),
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 8),
          Center(
            child: Text(
              diffDescs[_memoryDifficulty],
              style: const TextStyle(color: Color(0xFF6B7A90), fontSize: 11),
            ),
          ),
          const SizedBox(height: 14),
          _buildSlider(
            '记忆格数',
            _memoryStepConfig == 2 ? '自动递增' : '恒定 $_memoryStepConfig 格',
            _memoryStepConfig.toDouble(),
            2,
            9,
            7,
            accent,
            (v) {
              setModal(() => _memoryStepConfig = v.round());
              setState(() => _memoryStepConfig = v.round());
            },
          ),
        ],
      ),
      onStart: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => MemoryMatrixGameScreen(
            mode: _memoryMode,
            difficulty: _memoryDifficulty,
            fixedStep: _memoryStepConfig == 2 ? 0 : _memoryStepConfig,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final titles = ['轮盘', '幻色', '铭刻'];
    final colors = [
      const Color(0xFF64D2FF),
      const Color(0xFF4ECCA3),
      const Color(0xFFFFB74D),
    ];

    return Scaffold(
      body: VoidBackground(
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const SizedBox(width: 36),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(titles.length, (i) {
                        final active = _currentPage == i;
                        final col = colors[i];
                        return GestureDetector(
                          onTap: () {
                            VoidAudioEngine.instance.playTap();
                            _pageController.animateToPage(i,
                                duration: const Duration(milliseconds: 300),
                                curve: Curves.easeOutCubic);
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 250),
                            margin: const EdgeInsets.symmetric(horizontal: 6),
                            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                            decoration: BoxDecoration(
                              color: active ? const Color(0xFF182230) : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                  color: active ? col.withOpacity(0.6) : Colors.transparent,
                                  width: 0.8),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 5,
                                  height: 5,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: active ? col : const Color(0xFF384456),
                                    boxShadow: active ? [BoxShadow(color: col, blurRadius: 6)] : [],
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  titles[i],
                                  style: TextStyle(
                                    color: active ? const Color(0xFFE2E8F0) : const Color(0xFF55657E),
                                    fontSize: 12,
                                    letterSpacing: 1.2,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }),
                    ),
                    IconButton(
                      icon: Icon(
                        VoidAudioEngine.instance.isMuted
                            ? Icons.volume_off_outlined
                            : Icons.volume_up_outlined,
                        color: const Color(0xFF8F9CAE),
                        size: 20,
                      ),
                      onPressed: () async {
                        await VoidAudioEngine.instance.toggleMute();
                        setState(() {});
                      },
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PageView(
                  controller: _pageController,
                  onPageChanged: (idx) {
                    VoidAudioEngine.instance.playTap();
                    setState(() => _currentPage = idx);
                  },
                  children: [
                    _buildPortal(
                      title: '轮盘',
                      accent: const Color(0xFF64D2FF),
                      coreBg: const Color(0xFF10141D),
                      icon: Icons.lens_blur_outlined,
                      onTap: _openDiscConfig,
                      ringBuilder: () => RotationTransition(
                        turns: _discRotCtrl,
                        child: CustomPaint(
                            size: const Size(220, 220), painter: MinimalWheelLogoPainter()),
                      ),
                    ),
                    _buildPortal(
                      title: '幻色',
                      accent: const Color(0xFF4ECCA3),
                      coreBg: const Color(0xFF0F1A17),
                      icon: Icons.remove_red_eye_outlined,
                      onTap: _openStroopConfig,
                      ringBuilder: () => AnimatedBuilder(
                        animation: _stroopBreathCtrl,
                        builder: (_, __) => CustomPaint(
                          size: const Size(220, 220),
                          painter: MinimalStroopLogoPainter(_stroopBreathCtrl.value),
                        ),
                      ),
                    ),
                    _buildPortal(
                      title: '铭刻',
                      accent: const Color(0xFFFFB74D),
                      coreBg: const Color(0xFF1A150E),
                      icon: Icons.grid_view_rounded,
                      onTap: _openMemoryConfig,
                      ringBuilder: () => AnimatedBuilder(
                        animation: _memoryPulseCtrl,
                        builder: (_, __) => CustomPaint(
                          size: const Size(220, 220),
                          painter: MinimalMemoryLogoPainter(_memoryPulseCtrl.value),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPortal({
    required String title,
    required Color accent,
    required Color coreBg,
    required IconData icon,
    required VoidCallback onTap,
    required Widget Function() ringBuilder,
  }) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: onTap,
            child: Stack(
              alignment: Alignment.center,
              children: [
                ringBuilder(),
                Container(
                  width: 86,
                  height: 86,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: coreBg,
                    border: Border.all(color: accent.withOpacity(0.7), width: 1.2),
                    boxShadow: [
                      BoxShadow(color: accent.withOpacity(0.24), blurRadius: 22, spreadRadius: 2),
                    ],
                  ),
                  child: Center(child: Icon(icon, color: accent, size: 35)),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          Text(
            title,
            style: TextStyle(
              color: const Color(0xFFE2E8F0),
              fontSize: 22,
              letterSpacing: 10,
              shadows: [Shadow(color: accent, blurRadius: 12)],
            ),
          ),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 9),
              decoration: BoxDecoration(
                color: const Color(0xFF131924),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: const Color(0xFF2E3B4E), width: 0.9),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.tune, size: 14, color: Color(0xFF8F9CAE)),
                  SizedBox(width: 8),
                  Text('设定',
                      style: TextStyle(color: Color(0xFFE2E8F0), fontSize: 13, letterSpacing: 2)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------
// 3. 游戏一：舒尔特轮盘（预缓存排版防卡顿 + 机械怀表秒针滴答音）
// -------------------------------------------------------------
class SchulteWheelGameScreen extends StatefulWidget {
  final int ringCount;
  final int maxNumber;
  final int timeLimit;

  const SchulteWheelGameScreen({
    super.key,
    required this.ringCount,
    required this.maxNumber,
    required this.timeLimit,
  });

  @override
  State<SchulteWheelGameScreen> createState() => _SchulteWheelGameScreenState();
}

class _SchulteWheelGameScreenState extends State<SchulteWheelGameScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _wheelCtrl;
  late final List<List<int>> _ringNumbers;
  List<List<TextPainter>>? _cachedPainters;
  double? _cachedSize;

  Timer? _timer;
  late int _remaining;
  bool _canPop = false;

  @override
  void initState() {
    super.initState();
    _remaining = widget.timeLimit;
    _distributeNumbers();
    _wheelCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 35));

    Future.delayed(const Duration(milliseconds: 280), () {
      if (!mounted) return;
      showHollowDialog(
        context: context,
        title: '试炼说明',
        accentColor: const Color(0xFF64D2FF),
        content: const Text(
          '1. 视线保持聚焦于中央圆心，用余光展开外周视野。\n\n'
          '2. 轮盘旋转时，自数字 1 开始顺次搜寻并在心中默读。\n\n'
          '3. 倒计时终止前，尽可能默读到更大的目标数字。',
          style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, height: 1.6),
        ),
        actions: [
          Center(
            child: TextButton(
              onPressed: () {
                VoidAudioEngine.instance.playTap();
                Navigator.pop(context);
                _wheelCtrl.repeat();
                _startTimer();
              },
              child: const Text('凝聚心智 · 开始',
                  style: TextStyle(color: Color(0xFF64D2FF), letterSpacing: 2)),
            ),
          ),
        ],
      );
    });
  }

  @override
  void dispose() {
    _wheelCtrl.dispose();
    _timer?.cancel();
    super.dispose();
  }

  void _distributeNumbers() {
    final all = List.generate(widget.maxNumber, (i) => i + 1)..shuffle(Random());
    final minRatio = widget.ringCount == 2 ? 0.52 : (widget.ringCount == 3 ? 0.38 : 0.28);
    final radii = List.generate(
        widget.ringCount, (i) => minRatio + (1.0 - minRatio) * (i / (widget.ringCount - 1)));
    final totalSum = radii.reduce((a, b) => a + b);

    _ringNumbers = [];
    int start = 0;
    for (int r = 0; r < widget.ringCount; r++) {
      int count = (r == widget.ringCount - 1)
          ? widget.maxNumber - start
          : max(2, (widget.maxNumber * (radii[r] / totalSum)).round());
      int end = (start + count).clamp(0, widget.maxNumber);
      _ringNumbers.add(all.sublist(start, end));
      start = end;
    }
  }

  List<List<TextPainter>> _getCachedPainters(double size) {
    if (_cachedPainters != null && _cachedSize == size) {
      return _cachedPainters!;
    }
    _cachedSize = size;
    final maxR = size / 2 - 16;
    final minR = maxR * (widget.ringCount == 2 ? 0.52 : (widget.ringCount == 3 ? 0.38 : 0.28));
    final radii = List.generate(
        widget.ringCount, (i) => minR + (maxR - minR) * (i / (widget.ringCount - 1)));

    _cachedPainters = List.generate(_ringNumbers.length, (ringIdx) {
      final nums = _ringNumbers[ringIdx];
      final r = radii[ringIdx];
      final fontSize = ((2 * pi * r) / nums.length * 0.44).clamp(8.5, 15.0);
      final blur = (fontSize * 0.4).clamp(2.0, 5.0);

      return nums.map((num) {
        return TextPainter(
          text: TextSpan(
            text: '$num',
            style: TextStyle(
              color: const Color(0xFFF1F5F9),
              fontSize: fontSize,
              fontWeight: FontWeight.w600,
              fontFamily: 'monospace',
              shadows: [
                Shadow(color: const Color(0xFF64D2FF).withOpacity(0.85), blurRadius: blur),
              ],
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
      }).toList();
    });
    return _cachedPainters!;
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_remaining > 1) {
        setState(() => _remaining--);
        VoidAudioEngine.instance.playTick(urgent: _remaining <= 5);
        HapticFeedback.lightImpact();
      } else {
        t.cancel();
        _wheelCtrl.stop();
        setState(() => _remaining = 0);
        VoidAudioEngine.instance.playSuccess();
        HapticFeedback.mediumImpact();

        showHollowDialog(
          context: context,
          title: '心智凝视 · 终了',
          accentColor: const Color(0xFF64D2FF),
          content: Text(
            '已在 ${widget.timeLimit}s 动态旋转中完成视界展开\n'
            '圈层: ${widget.ringCount} 圈  |  总数: 1~${widget.maxNumber}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, height: 1.6),
          ),
          actions: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: () {
                    VoidAudioEngine.instance.playTap();
                    Navigator.pop(context);
                    _safeExit();
                  },
                  child: const Text('返回殿堂', style: TextStyle(color: Color(0xFF8F9CAE))),
                ),
                TextButton(
                  onPressed: () {
                    VoidAudioEngine.instance.playTap();
                    Navigator.pop(context);
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (_) => SchulteWheelGameScreen(
                          ringCount: widget.ringCount,
                          maxNumber: widget.maxNumber,
                          timeLimit: widget.timeLimit,
                        ),
                      ),
                    );
                  },
                  child: const Text('再次试炼', style: TextStyle(color: Color(0xFF64D2FF))),
                ),
              ],
            ),
          ],
        );
      }
    });
  }

  void _safeExit() {
    _timer?.cancel();
    _wheelCtrl.stop();
    setState(() => _canPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size.width * 0.92;
    final painters = _getCachedPainters(size);

    return GameScaffold(
      canPop: _canPop,
      onExit: _safeExit,
      subtitle: '凝视中心 · 依次顺次默读 1 ➔ N',
      footer: '· 保持视线落在圆心以展开外周视野 ·',
      rightBadge: _TimeBadge(seconds: _remaining, color: const Color(0xFF64D2FF)),
      body: RepaintBoundary(
        child: SizedBox(
          width: size,
          height: size,
          child: AnimatedBuilder(
            animation: _wheelCtrl,
            builder: (_, __) => CustomPaint(
              painter: SchulteDiscPainter(
                rotationAngle: _wheelCtrl.value * 2 * pi,
                textPainters: painters,
                ringCount: widget.ringCount,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class SchulteDiscPainter extends CustomPainter {
  final double rotationAngle;
  final List<List<TextPainter>> textPainters;
  final int ringCount;

  SchulteDiscPainter({
    required this.rotationAngle,
    required this.textPainters,
    required this.ringCount,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2 - 16;
    final minR = maxR * (ringCount == 2 ? 0.52 : (ringCount == 3 ? 0.38 : 0.28));

    final eyeR = maxR * 0.168;
    canvas.drawCircle(center, eyeR, Paint()..color = const Color(0xFF131A26));
    canvas.drawCircle(
      center,
      eyeR,
      Paint()
        ..color = const Color(0xFF64D2FF).withOpacity(0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
    canvas.drawCircle(center, 3, Paint()..color = const Color(0xFF64D2FF));

    final radii = List.generate(
        ringCount, (i) => minR + (maxR - minR) * (i / (ringCount - 1)));
    final linePaint = Paint()
      ..color = const Color(0xFF1F2937)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    final dotPaint = Paint()..color = const Color(0xFF384456);

    for (var r in radii) {
      canvas.drawCircle(center, r, linePaint);
    }

    for (int ringIdx = 0; ringIdx < textPainters.length; ringIdx++) {
      final painters = textPainters[ringIdx];
      final r = radii[ringIdx];
      final count = painters.length;

      for (int i = 0; i < count; i++) {
        final angle = (2 * pi / count) * i + rotationAngle;
        final pos = Offset(center.dx + r * cos(angle), center.dy + r * sin(angle));
        canvas.drawCircle(pos, 1.2, dotPaint);

        final tp = painters[i];
        tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy - tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(covariant SchulteDiscPainter old) =>
      old.rotationAngle != rotationAngle;
}

// -------------------------------------------------------------
// 4. 游戏二：幻色（斯特鲁普抗干扰训练 + 命中/失误音效）
// -------------------------------------------------------------
class StroopGameScreen extends StatefulWidget {
  final int timeLimit;
  const StroopGameScreen({super.key, required this.timeLimit});

  @override
  State<StroopGameScreen> createState() => _StroopGameScreenState();
}

class _StroopGameScreenState extends State<StroopGameScreen>
    with SingleTickerProviderStateMixin {
  final _palette = [
    {'name': '绯红', 'color': const Color(0xFFFF5252)},
    {'name': '冷青', 'color': const Color(0xFF64D2FF)},
    {'name': '苍翠', 'color': const Color(0xFF4ECCA3)},
    {'name': '灵金', 'color': const Color(0xFFFFD166)},
  ];

  late String _text;
  late Color _color;
  late int _targetIdx;

  int _score = 0;
  int _combo = 0;
  int _maxCombo = 0;
  int _attempts = 0;

  Timer? _timer;
  late int _remaining;
  bool _canPop = false;
  late final AnimationController _shakeCtrl;
  final _rng = Random();

  @override
  void initState() {
    super.initState();
    _remaining = widget.timeLimit;
    _nextQuestion();
    _shakeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));

    Future.delayed(const Duration(milliseconds: 280), () {
      if (!mounted) return;
      showHollowDialog(
        context: context,
        title: '幻色 · 破幻试炼',
        accentColor: const Color(0xFF4ECCA3),
        content: const Text(
          '1. 屏幕中央会出现带有颜色的文字。\n\n'
          '2. 彻底忽略文字字义，只识别文字【实际展示的颜色】。\n\n'
          '3. 克服大脑阅读惯性，以极速点击下方对应的真实色彩符石。',
          style: TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, height: 1.6),
        ),
        actions: [
          Center(
            child: TextButton(
              onPressed: () {
                VoidAudioEngine.instance.playTap();
                Navigator.pop(context);
                _startTimer();
              },
              child: const Text('破除迷障 · 开始',
                  style: TextStyle(color: Color(0xFF4ECCA3), letterSpacing: 2)),
            ),
          ),
        ],
      );
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _shakeCtrl.dispose();
    super.dispose();
  }

  void _nextQuestion() {
    final tIdx = _rng.nextInt(_palette.length);
    int cIdx = _rng.nextInt(_palette.length);
    if (cIdx == tIdx && _rng.nextDouble() > 0.2) cIdx = (cIdx + 1) % _palette.length;
    _text = _palette[tIdx]['name'] as String;
    _color = _palette[cIdx]['color'] as Color;
    _targetIdx = cIdx;
  }

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (_remaining > 1) {
        setState(() => _remaining--);
        VoidAudioEngine.instance.playTick(urgent: _remaining <= 5);
        HapticFeedback.lightImpact();
      } else {
        t.cancel();
        setState(() => _remaining = 0);
        VoidAudioEngine.instance.playSuccess();
        HapticFeedback.mediumImpact();

        final acc = _attempts > 0 ? (_score / _attempts * 100).toStringAsFixed(1) : '0.0';
        showHollowDialog(
          context: context,
          title: '幻色消退 · 试炼结算',
          accentColor: const Color(0xFF4ECCA3),
          content: Text(
            '正确得分: $_score\n命中率: $acc%  |  最高连击: $_maxCombo',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 14, height: 1.8),
          ),
          actions: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: () {
                    VoidAudioEngine.instance.playTap();
                    Navigator.pop(context);
                    _safeExit();
                  },
                  child: const Text('返回殿堂', style: TextStyle(color: Color(0xFF8F9CAE))),
                ),
                TextButton(
                  onPressed: () {
                    VoidAudioEngine.instance.playTap();
                    Navigator.pop(context);
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                          builder: (_) => StroopGameScreen(timeLimit: widget.timeLimit)),
                    );
                  },
                  child: const Text('再破一次', style: TextStyle(color: Color(0xFF4ECCA3))),
                ),
              ],
            ),
          ],
        );
      }
    });
  }

  void _onSelect(int idx) {
    if (_remaining <= 0) return;
    _attempts++;
    if (idx == _targetIdx) {
      VoidAudioEngine.instance.playTap();
      HapticFeedback.lightImpact();
      setState(() {
        _score++;
        _combo++;
        if (_combo > _maxCombo) _maxCombo = _combo;
        _nextQuestion();
      });
    } else {
      VoidAudioEngine.instance.playError();
      HapticFeedback.heavyImpact();
      _shakeCtrl.forward().then((_) => _shakeCtrl.reverse());
      setState(() {
        _combo = 0;
        _nextQuestion();
      });
    }
  }

  void _safeExit() {
    _timer?.cancel();
    setState(() => _canPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    return GameScaffold(
      canPop: _canPop,
      onExit: _safeExit,
      subtitle: '选择字体的【实际颜色】 · 忽略字义',
      footer: '· 抑制阅读本能，捕获纯粹色彩 ·',
      rightBadge: _TimeBadge(seconds: _remaining, color: const Color(0xFF4ECCA3)),
      centerBadge: _combo >= 3
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1B2A22),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF4ECCA3), width: 0.8),
              ),
              child: Text('COMBO x$_combo',
                  style: const TextStyle(
                      color: Color(0xFF4ECCA3), fontSize: 11, fontWeight: FontWeight.bold)),
            )
          : null,
      body: Column(
        children: [
          AnimatedBuilder(
            animation: _shakeCtrl,
            builder: (_, child) => Transform.translate(
              offset: Offset(sin(_shakeCtrl.value * 3 * pi) * 12, 0),
              child: child,
            ),
            child: Container(
              width: 220,
              height: 150,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: const Color(0xFF111722).withOpacity(0.85),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _color.withOpacity(0.4), width: 1.2),
                boxShadow: [BoxShadow(color: _color.withOpacity(0.15), blurRadius: 28)],
              ),
              child: Text(
                _text,
                style: TextStyle(
                  color: _color,
                  fontSize: 48,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 8,
                  shadows: [Shadow(color: _color, blurRadius: 16)],
                ),
              ),
            ),
          ),
          const SizedBox(height: 50),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                crossAxisSpacing: 16,
                mainAxisSpacing: 16,
                childAspectRatio: 2.3,
              ),
              itemCount: _palette.length,
              itemBuilder: (_, idx) {
                final col = _palette[idx]['color'] as Color;
                final name = _palette[idx]['name'] as String;
                return GestureDetector(
                  onTap: () => _onSelect(idx),
                  child: Container(
                    decoration: BoxDecoration(
                      color: const Color(0xFF131924),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: col.withOpacity(0.7)),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: col,
                            boxShadow: [BoxShadow(color: col, blurRadius: 6)],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(name,
                            style: const TextStyle(
                                color: Color(0xFFE2E8F0), fontSize: 15, letterSpacing: 3)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// -------------------------------------------------------------
// 5. 游戏三：铭刻（修复连线残影 Bug + 平缓阶梯难度 + 恒定格数 + 五声音阶）
// -------------------------------------------------------------
enum _MemoryPhase { intro, display, buffer, recall, feedback }

class MemoryMatrixGameScreen extends StatefulWidget {
  final int mode;       // 0: 正序, 1: 倒序, 2: 无尽
  final int difficulty; // 0: 舒缓, 1: 均衡, 2: 严苛
  final int fixedStep;  // 0: 自动递增, 3~9: 恒定格数

  const MemoryMatrixGameScreen({
    super.key,
    required this.mode,
    required this.difficulty,
    required this.fixedStep,
  });

  @override
  State<MemoryMatrixGameScreen> createState() => _MemoryMatrixGameScreenState();
}

class _MemoryMatrixGameScreenState extends State<MemoryMatrixGameScreen>
    with SingleTickerProviderStateMixin {
  _MemoryPhase _phase = _MemoryPhase.intro;
  int _round = 1;
  late int _stepCount;
  late int _activeGridSize;
  int _lives = 3;
  int _combo = 0;

  List<int> _sequence = [];
  List<int> _selected = [];
  int? _activeTile;
  int? _errorTile;
  int? _lastDragTile;

  bool _canPop = false;
  bool _disposed = false;
  late final AnimationController _shakeCtrl;

  // 根据当前轮次与设定计算本轮【记忆格数】
  int _computeStepForRound(int round) {
    if (widget.fixedStep > 0) return widget.fixedStep;
    final stepInterval = widget.difficulty == 0 ? 3 : (widget.difficulty == 1 ? 2 : 1);
    return (3 + (round - 1) ~/ stepInterval).clamp(3, 12);
  }

  // 根据当前轮次与难度曲线计算【棋盘规格】
  int _computeGridSizeForRound(int round, int currentStep) {
    int size;
    if (widget.mode == 2) {
      size = 5;
    } else {
      final gridInterval = widget.difficulty == 0 ? 4 : (widget.difficulty == 1 ? 3 : 2);
      final baseSize = widget.difficulty == 2 ? 4 : 3;
      final growth = (round - 1) ~/ gridInterval;
      size = (baseSize + growth).clamp(3, 7);
    }
    while (size * size < currentStep + 2 && size < 7) {
      size++;
    }
    return size;
  }

  int get _speedMs {
    final baseSpeed = widget.difficulty == 0 ? 900 : (widget.difficulty == 1 ? 750 : 560);
    final decay = widget.difficulty == 0 ? 10 : (widget.difficulty == 1 ? 15 : 22);
    final minSpeed = widget.difficulty == 0 ? 520 : (widget.difficulty == 1 ? 400 : 280);
    return (baseSpeed - (_round - 1) * decay).clamp(minSpeed, baseSpeed);
  }

  @override
  void initState() {
    super.initState();
    _stepCount = _computeStepForRound(_round);
    _activeGridSize = _computeGridSizeForRound(_round, _stepCount);
    _shakeCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 280));

    Future.delayed(const Duration(milliseconds: 280), () {
      if (!mounted) return;
      final modeNames = ['标准正序', '镜像倒序', '无尽突变'];
      final rule = widget.mode == 1
          ? '2. 缓冲结束后，按【完全相反的倒序】点亮或一笔画连出格子。'
          : '2. 缓冲结束后，按【刚刚出现的先后顺序】点亮或一笔画连出格子。';
      showHollowDialog(
        context: context,
        title: '铭刻 · ${modeNames[widget.mode]}',
        accentColor: const Color(0xFFFFB74D),
        content: Text(
          '1. 观察棋盘依次点亮的符石与递进音阶，随后熄灭进入 0.5 秒心智缓冲。\n\n'
          '$rule\n\n'
          '3. 支持单次轻点，也可直接在棋盘上【一笔画连线划动】。',
          style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, height: 1.6),
        ),
        actions: [
          Center(
            child: TextButton(
              onPressed: () {
                VoidAudioEngine.instance.playTap();
                Navigator.pop(context);
                _startRound();
              },
              child: const Text('凝神铭记 · 开始',
                  style: TextStyle(color: Color(0xFFFFB74D), letterSpacing: 2)),
            ),
          ),
        ],
      );
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _shakeCtrl.dispose();
    super.dispose();
  }

  Future<void> _startRound() async {
    if (_disposed || !mounted) return;

    final nextStep = _computeStepForRound(_round);
    final nextGridSize = _computeGridSizeForRound(_round, nextStep);
    final total = nextGridSize * nextGridSize;

    _sequence = (List.generate(total, (i) => i)..shuffle(Random()))
        .take(nextStep.clamp(3, total))
        .toList();

    setState(() {
      _stepCount = nextStep;
      _activeGridSize = nextGridSize;
      _phase = _MemoryPhase.display;
      _selected = [];
      _activeTile = null;
      _errorTile = null;
      _lastDragTile = null;
    });

    await Future.delayed(const Duration(milliseconds: 420));

    // 1. 展示阶段
    for (int i = 0; i < _sequence.length; i++) {
      if (_disposed || !mounted) return;
      setState(() => _activeTile = _sequence[i]);
      VoidAudioEngine.instance.playScaleStep(i);
      HapticFeedback.selectionClick();
      await Future.delayed(Duration(milliseconds: (_speedMs * 0.65).round()));
      if (_disposed || !mounted) return;
      setState(() => _activeTile = null);
      await Future.delayed(Duration(milliseconds: (_speedMs * 0.35).round()));
    }

    // 2. 0.5秒缓冲阶段
    if (_disposed || !mounted) return;
    setState(() => _phase = _MemoryPhase.buffer);
    await Future.delayed(const Duration(milliseconds: 500));

    // 3. 复原阶段
    if (_disposed || !mounted) return;
    setState(() => _phase = _MemoryPhase.recall);
  }

  void _onPointer(Offset pos, double boardSize) {
    if (_phase != _MemoryPhase.recall) return;
    if (pos.dx < 0 || pos.dy < 0 || pos.dx > boardSize || pos.dy > boardSize) return;

    final cell = boardSize / _activeGridSize;
    final idx = (pos.dy / cell).floor().clamp(0, _activeGridSize - 1) * _activeGridSize +
        (pos.dx / cell).floor().clamp(0, _activeGridSize - 1);

    if (idx == _lastDragTile || _selected.contains(idx)) return;
    _lastDragTile = idx;

    final targetSeq = widget.mode == 1 ? _sequence.reversed.toList() : _sequence;
    final currentStep = _selected.length;

    if (idx == targetSeq[currentStep]) {
      VoidAudioEngine.instance.playScaleStep(currentStep);
      HapticFeedback.lightImpact();
      setState(() => _selected.add(idx));
      if (_selected.length == targetSeq.length) {
        _handleRoundEnd(success: true);
      }
    } else {
      _handleRoundEnd(success: false, wrongIdx: idx);
    }
  }

  Future<void> _handleRoundEnd({required bool success, int? wrongIdx}) async {
    setState(() {
      _phase = _MemoryPhase.feedback;
      if (success) {
        _combo++;
        _round++;
      } else {
        _errorTile = wrongIdx;
        _combo = 0;
        _lives--;
      }
    });

    if (success) {
      VoidAudioEngine.instance.playSuccess();
      HapticFeedback.mediumImpact();
      await Future.delayed(const Duration(milliseconds: 480));
      _startRound();
    } else {
      VoidAudioEngine.instance.playError();
      HapticFeedback.heavyImpact();
      _shakeCtrl.forward().then((_) => _shakeCtrl.reverse());
      await Future.delayed(const Duration(milliseconds: 680));
      if (_disposed || !mounted) return;

      if (_lives <= 0) {
        showHollowDialog(
          context: context,
          title: '铭刻消散 · 试炼终了',
          accentColor: const Color(0xFFFFB74D),
          content: Text(
            '通过试炼轮次: ${_round - 1} 轮\n'
            '最高记忆格数: $_stepCount 格  |  最终棋盘: $_activeGridSize × $_activeGridSize',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Color(0xFFCBD5E1), fontSize: 13, height: 1.8),
          ),
          actions: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: () {
                    VoidAudioEngine.instance.playTap();
                    Navigator.pop(context);
                    _safeExit();
                  },
                  child: const Text('返回殿堂', style: TextStyle(color: Color(0xFF8F9CAE))),
                ),
                TextButton(
                  onPressed: () {
                    VoidAudioEngine.instance.playTap();
                    Navigator.pop(context);
                    Navigator.pushReplacement(
                      context,
                      MaterialPageRoute(
                        builder: (_) => MemoryMatrixGameScreen(
                          mode: widget.mode,
                          difficulty: widget.difficulty,
                          fixedStep: widget.fixedStep,
                        ),
                      ),
                    );
                  },
                  child: const Text('再次铭刻', style: TextStyle(color: Color(0xFFFFB74D))),
                ),
              ],
            ),
          ],
        );
      } else {
        _startRound();
      }
    }
  }

  void _safeExit() {
    _disposed = true;
    setState(() => _canPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.pop(context);
    });
  }

  String get _hintText => switch (_phase) {
        _MemoryPhase.intro => '准备凝聚心神...',
        _MemoryPhase.display => '铭记符石点亮顺序',
        _MemoryPhase.buffer => '心智缓冲 · 锁定印记',
        _MemoryPhase.recall => widget.mode == 1 ? '请按【倒序】点按或连线复原' : '请按【顺序】点按或连线复原',
        _MemoryPhase.feedback => _errorTile != null ? '序列紊乱 · 魂火受损' : '铭刻契合 · 推进下一轮',
      };

  @override
  Widget build(BuildContext context) {
    final boardSize = MediaQuery.of(context).size.width * 0.88;
    final gap = _activeGridSize >= 6 ? 4.0 : 8.0;

    return GameScaffold(
      canPop: _canPop,
      onExit: _safeExit,
      subtitle: _hintText,
      footer: _combo > 0 ? '连胜契合 : $_combo' : '· 轻点或一笔画连线复原印记 ·',
      centerBadge: Row(
        children: List.generate(
          3,
          (i) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 3),
            child: Icon(
              i < _lives ? Icons.shield : Icons.shield_outlined,
              size: 16,
              color: i < _lives ? const Color(0xFFFFB74D) : const Color(0xFF384456),
            ),
          ),
        ),
      ),
      rightBadge: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: const Color(0xFF141A24),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: const Color(0xFF2E384D), width: 0.8),
        ),
        child: Text(
          '第$_round轮 · $_activeGridSize×$_activeGridSize · $_stepCount格',
          style: const TextStyle(
              color: Color(0xFFFFB74D),
              fontSize: 11,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold),
        ),
      ),
      body: AnimatedBuilder(
        animation: _shakeCtrl,
        builder: (_, child) => Transform.translate(
          offset: Offset(sin(_shakeCtrl.value * 3 * pi) * 10, 0),
          child: child,
        ),
        child: Listener(
          onPointerDown: (e) {
            _lastDragTile = null;
            _onPointer(e.localPosition, boardSize);
          },
          onPointerMove: (e) => _onPointer(e.localPosition, boardSize),
          onPointerUp: (_) => _lastDragTile = null,
          child: SizedBox(
            width: boardSize,
            height: boardSize,
            child: Stack(
              children: [
                GridView.builder(
                  physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _activeGridSize,
                    crossAxisSpacing: gap,
                    mainAxisSpacing: gap,
                  ),
                  itemCount: _activeGridSize * _activeGridSize,
                  itemBuilder: (_, idx) {
                    final active = _activeTile == idx || _selected.contains(idx);
                    final err = _errorTile == idx;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 140),
                      decoration: BoxDecoration(
                        color: err
                            ? const Color(0xFF4A1818)
                            : (active
                                ? const Color(0xFF332613)
                                : const Color(0xFF141B26).withOpacity(0.85)),
                        borderRadius: BorderRadius.circular(_activeGridSize >= 6 ? 4 : 8),
                        border: Border.all(
                          color: err
                              ? const Color(0xFFFF5252)
                              : (active
                                  ? const Color(0xFFFFB74D)
                                  : const Color(0xFF2B3648)),
                        ),
                        boxShadow: err
                            ? [const BoxShadow(color: Color(0xFFFF5252), blurRadius: 12)]
                            : (active
                                ? [
                                    BoxShadow(
                                        color: const Color(0xFFFFB74D).withOpacity(0.5),
                                        blurRadius: 12)
                                  ]
                                : []),
                      ),
                    );
                  },
                ),
                if (_selected.length > 1)
                  IgnorePointer(
                    child: CustomPaint(
                      size: Size(boardSize, boardSize),
                      painter: _MemoryTrailPainter(_selected, _activeGridSize),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MemoryTrailPainter extends CustomPainter {
  final List<int> indices;
  final int gridSize;
  _MemoryTrailPainter(this.indices, this.gridSize);

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / gridSize;
    final paint = Paint()
      ..color = const Color(0xFFFFB74D).withOpacity(0.75)
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    final path = Path();
    for (int i = 0; i < indices.length; i++) {
      final pt = Offset((indices[i] % gridSize + 0.5) * cell, (indices[i] ~/ gridSize + 0.5) * cell);
      i == 0 ? path.moveTo(pt.dx, pt.dy) : path.lineTo(pt.dx, pt.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _MemoryTrailPainter old) => true;
}

// -------------------------------------------------------------
// 6. 极简 Logo 画笔与计时徽章组件
// -------------------------------------------------------------
class _TimeBadge extends StatelessWidget {
  final int seconds;
  final Color color;
  const _TimeBadge({required this.seconds, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF141A24),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF2E384D), width: 0.8),
      ),
      child: Row(
        children: [
          Icon(Icons.access_time, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            '${seconds}s',
            style: TextStyle(
              color: const Color(0xFFE2E8F0),
              fontSize: 14,
              fontFamily: 'monospace',
              fontWeight: FontWeight.bold,
              shadows: [Shadow(color: color, blurRadius: 8)],
            ),
          ),
        ],
      ),
    );
  }
}

class MinimalWheelLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    canvas.drawCircle(c, r - 4, Paint()..color = const Color(0xFF263242)..style = PaintingStyle.stroke);
    canvas.drawCircle(c, r * 0.65, Paint()..color = const Color(0xFF1B2430)..style = PaintingStyle.stroke..strokeWidth = 0.8);

    final tickPaint = Paint()..color = const Color(0xFF64D2FF).withOpacity(0.35);
    for (int i = 0; i < 24; i++) {
      final a = (2 * pi / 24) * i;
      canvas.drawLine(
        Offset(c.dx + (r - 12) * cos(a), c.dy + (r - 12) * sin(a)),
        Offset(c.dx + (r - 4) * cos(a), c.dy + (r - 4) * sin(a)),
        tickPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class MinimalStroopLogoPainter extends CustomPainter {
  final double breath;
  MinimalStroopLogoPainter(this.breath);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;
    final arcPaint = Paint()..color = const Color(0xFF263B34)..style = PaintingStyle.stroke;

    canvas.drawArc(Rect.fromCircle(center: c, radius: r - 6), -pi / 4, pi * 0.9, false, arcPaint);
    canvas.drawArc(Rect.fromCircle(center: c, radius: r - 6), 3 * pi / 4, pi * 0.9, false, arcPaint);

    final prism = Paint()..color = const Color(0xFF4ECCA3).withOpacity(0.3 + 0.3 * breath);
    final ext = 4.0 * breath;
    canvas.drawLine(Offset(c.dx, c.dy - r + 12 - ext), Offset(c.dx, c.dy - r + 28), prism);
    canvas.drawLine(Offset(c.dx, c.dy + r - 12 + ext), Offset(c.dx, c.dy + r - 28), prism);
    canvas.drawLine(Offset(c.dx - r + 12 - ext, c.dy), Offset(c.dx - r + 28, c.dy), prism);
    canvas.drawLine(Offset(c.dx + r - 12 + ext, c.dy), Offset(c.dx + r - 28, c.dy), prism);

    final diamond = Paint()..color = const Color(0xFFFF5252).withOpacity(0.4);
    for (int i = 0; i < 4; i++) {
      final a = (pi / 2) * i + (pi / 4);
      final dx = c.dx + (r * 0.65) * cos(a);
      final dy = c.dy + (r * 0.65) * sin(a);
      canvas.drawPath(
        Path()
          ..moveTo(dx, dy - 2.5)
          ..lineTo(dx + 2.5, dy)
          ..lineTo(dx, dy + 2.5)
          ..lineTo(dx - 2.5, dy)
          ..close(),
        diamond,
      );
    }
  }

  @override
  bool shouldRepaint(covariant MinimalStroopLogoPainter old) => old.breath != breath;
}

class MinimalMemoryLogoPainter extends CustomPainter {
  final double pulse;
  MinimalMemoryLogoPainter(this.pulse);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;

    canvas.drawPath(
      Path()
        ..moveTo(c.dx, c.dy - r + 8)
        ..lineTo(c.dx + r - 8, c.dy)
        ..lineTo(c.dx, c.dy + r - 8)
        ..lineTo(c.dx - r + 8, c.dy)
        ..close(),
      Paint()..color = const Color(0xFF3A2E1E)..style = PaintingStyle.stroke,
    );

    final dist = r * 0.52;
    final nodes = [
      Offset(c.dx, c.dy - dist),
      Offset(c.dx + dist, c.dy),
      Offset(c.dx, c.dy + dist),
      Offset(c.dx - dist, c.dy),
    ];

    final nodePaint = Paint()..color = const Color(0xFFFFB74D).withOpacity(0.35 + 0.4 * pulse);
    final webPaint = Paint()
      ..color = const Color(0xFFFFB74D).withOpacity(0.18 + 0.2 * pulse)
      ..strokeWidth = 0.8;

    for (int i = 0; i < 4; i++) {
      canvas.drawCircle(nodes[i], 2.5, nodePaint);
      canvas.drawLine(nodes[i], nodes[(i + 1) % 4], webPaint);
    }
  }

  @override
  bool shouldRepaint(covariant MinimalMemoryLogoPainter old) => old.pulse != pulse;
}