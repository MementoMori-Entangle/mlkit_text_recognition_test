import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import 'package:image/image.dart' as img;
import 'dart:math' as math;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  // This widget is the root of your application.
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(
        // This is the theme of your application.
        //
        // TRY THIS: Try running your application with "flutter run". You'll see
        // the application has a purple toolbar. Then, without quitting the app,
        // try changing the seedColor in the colorScheme below to Colors.green
        // and then invoke "hot reload" (save your changes or press the "hot
        // reload" button in a Flutter-supported IDE, or press "r" if you used
        // the command line to start the app).
        //
        // Notice that the counter didn't reset back to zero; the application
        // state is not lost during the reload. To reset the state, use hot
        // restart instead.
        //
        // This works for code too, not just values: Most code changes can be
        // tested with just a hot reload.
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const MyHomePage(title: 'OCR Demo'),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key, required this.title});

  // This widget is the home page of your application. It is stateful, meaning
  // that it has a State object (defined below) that contains fields that affect
  // how it looks.

  // This class is the configuration for the state. It holds the values (in this
  // case the title) provided by the parent (in this case the App widget) and
  // used by the build method of the State. Fields in a Widget subclass are
  // always marked "final".

  final String title;

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

enum OcrMode { normal, unwrap }

class _MyHomePageState extends State<MyHomePage> {
  CameraController? _cameraController;
  List<CameraDescription>? _cameras;
  String _recognizedText = '';
  bool _isBusy = false;
  OcrMode _ocrMode = OcrMode.normal;
  double _r1Ratio = 0.33; // r1 = 画像短辺 * _r1Ratio
  double _r2Ratio = 0.5; // r2 = 画像短辺 * _r2Ratio
  String? _unwrapImagePath;
  bool _autoSelectBest = false;
  double _centerXRatio = 0.5; // 画像幅に対する中心Xの比率
  double _centerYRatio = 0.5; // 画像高さに対する中心Yの比率
  double? _maskRadiusRatio = 0.5; // 通常パターンのマスク円半径（画像短辺に対する比率）
  bool _linkR1R2 = false;
  double _r1r2Diff = 0.17; // r2 = r1 + _r1r2Diff で連動
  int _unwrapShift = 0; // アンラップ画像のシフト量（ピクセル）
  Key _previewKey = UniqueKey(); // プレビュー画像用のキー
  bool _splitNormal = true; // 通常パターン分割有無
  String? _maskedImagePath; // 通常パターン:マスク画像
  String? _upperImagePath; // 上下分割:上
  String? _lowerImagePath; // 上下分割:下

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    _cameras = await availableCameras();
    if (_cameras != null && _cameras!.isNotEmpty) {
      _cameraController = CameraController(
        _cameras![0],
        ResolutionPreset.max, // 解像度を最大に
        enableAudio: false,
      );
      await _cameraController!.initialize();
      if (mounted) setState(() {});
    }
  }

  Future<void> _captureAndRecognize() async {
    if (_cameraController == null ||
        !_cameraController!.value.isInitialized ||
        _isBusy) {
      return;
    }
    setState(() {
      _isBusy = true;
    });
    try {
      final XFile file = await _cameraController!.takePicture();
      final bytes = await file.readAsBytes();
      final original = img.decodeImage(bytes);
      if (original != null) {
        final gray = img.grayscale(original);
        final contrast = img.adjustColor(gray, gamma: 0.7, contrast: 1.5);
        final tempDir = await getTemporaryDirectory();
        final centerX = (contrast.width * _centerXRatio).round();
        final centerY = (contrast.height * _centerYRatio).round();
        final minSide =
            contrast.width < contrast.height ? contrast.width : contrast.height;
        final r1 = (minSide * _r1Ratio).round();
        final r2 = (minSide * _r2Ratio).round();
        // --- 通常パターン ---
        String normalText = '';
        String? maskedPath;
        String? upperPath;
        String? lowerPath;
        if (_ocrMode == OcrMode.normal && !_splitNormal) {
          // 分割しない
          final masked = img.Image(
            width: contrast.width,
            height: contrast.height,
          );
          final radius = ((_maskRadiusRatio ?? 0.5) * minSide).round();
          for (int y = 0; y < contrast.height; y++) {
            for (int x = 0; x < contrast.width; x++) {
              final dx = x - centerX;
              final dy = y - centerY;
              if (dx * dx + dy * dy <= radius * radius) {
                masked.setPixel(x, y, contrast.getPixel(x, y));
              } else {
                masked.setPixelRgba(x, y, 255, 255, 255, 255);
              }
            }
          }
          maskedPath = '${tempDir.path}/masked.jpg';
          await File(maskedPath).writeAsBytes(img.encodeJpg(masked));
          final textRecognizer = TextRecognizer();
          final result = await textRecognizer.processImage(
            InputImage.fromFilePath(maskedPath),
          );
          normalText = result.text;
          await textRecognizer.close();
        } else if (_ocrMode == OcrMode.normal && _splitNormal) {
          // 上下分割
          final masked = img.Image(
            width: contrast.width,
            height: contrast.height,
          );
          final radius = ((_maskRadiusRatio ?? 0.5) * minSide).round();
          for (int y = 0; y < contrast.height; y++) {
            for (int x = 0; x < contrast.width; x++) {
              final dx = x - centerX;
              final dy = y - centerY;
              if (dx * dx + dy * dy <= radius * radius) {
                masked.setPixel(x, y, contrast.getPixel(x, y));
              } else {
                masked.setPixelRgba(x, y, 255, 255, 255, 255);
              }
            }
          }
          final upper = img.copyCrop(
            masked,
            x: 0,
            y: 0,
            width: masked.width,
            height: masked.height ~/ 2,
          );
          final lower = img.copyCrop(
            masked,
            x: 0,
            y: masked.height ~/ 2,
            width: masked.width,
            height: masked.height - masked.height ~/ 2,
          );
          upperPath = '${tempDir.path}/upper.jpg';
          lowerPath = '${tempDir.path}/lower.jpg';
          await File(upperPath).writeAsBytes(img.encodeJpg(upper));
          await File(lowerPath).writeAsBytes(img.encodeJpg(lower));
          final textRecognizer = TextRecognizer();
          final upperText = await textRecognizer.processImage(
            InputImage.fromFilePath(upperPath),
          );
          final lowerText = await textRecognizer.processImage(
            InputImage.fromFilePath(lowerPath),
          );
          normalText = '${upperText.text}\n${lowerText.text}';
          await textRecognizer.close();
        }
        setState(() {
          _maskedImagePath = maskedPath;
          _upperImagePath = upperPath;
          _lowerImagePath = lowerPath;
        });

        // --- アンラップパターン（上下反転） ---
        final unwrapHeight = r2 - r1;
        final unwrapWidth = 360;
        final unwrap = img.Image(width: unwrapWidth, height: unwrapHeight);
        for (int theta = 0; theta < unwrapWidth; theta++) {
          final angle = theta * 2 * 3.1415926535 / unwrapWidth;
          for (int r = 0; r < unwrapHeight; r++) {
            final rr = r1 + r;
            final x = (centerX + rr * math.cos(angle)).round();
            final y = (centerY + rr * math.sin(angle)).round();
            if (x >= 0 && x < contrast.width && y >= 0 && y < contrast.height) {
              unwrap.setPixel(theta, r, contrast.getPixel(x, y));
            } else {
              unwrap.setPixelRgba(theta, r, 255, 255, 255, 255);
            }
          }
        }
        final flippedUnwrap = img.flipVertical(unwrap);
        final unwrapPath = '${tempDir.path}/unwrap.jpg';
        await File(unwrapPath).writeAsBytes(img.encodeJpg(flippedUnwrap));
        _unwrapImagePath = unwrapPath;
        final textRecognizer2 = TextRecognizer();
        final unwrapResult = await textRecognizer2.processImage(
          InputImage.fromFilePath(unwrapPath),
        );
        final unwrapText = unwrapResult.text;
        await textRecognizer2.close();

        if (_autoSelectBest) {
          // --- 精度判定: 非空文字数が多い方を採用 ---
          final normalScore = normalText.replaceAll(RegExp(r'\s'), '').length;
          final unwrapScore = unwrapText.replaceAll(RegExp(r'\s'), '').length;
          String adoptedText;
          String adoptedPattern;
          if (unwrapScore > normalScore) {
            adoptedText = unwrapText;
            adoptedPattern = 'アンラップパターン（上下反転）';
          } else {
            adoptedText = normalText;
            adoptedPattern = '通常パターン';
          }
          setState(() {
            _recognizedText = '[採用: $adoptedPattern]\n$adoptedText';
          });
        } else {
          // UIで選択されたパターンのみ表示
          if (_ocrMode == OcrMode.normal) {
            setState(() {
              _recognizedText = normalText;
            });
          } else {
            setState(() {
              _recognizedText = unwrapText;
            });
          }
        }
      } else {
        setState(() {
          _recognizedText = '画像のデコードに失敗しました';
          _maskedImagePath = null;
          _upperImagePath = null;
          _lowerImagePath = null;
        });
      }
    } catch (e) {
      setState(() {
        _recognizedText = 'Error: \n$e';
        _maskedImagePath = null;
        _upperImagePath = null;
        _lowerImagePath = null;
      });
    } finally {
      setState(() {
        _isBusy = false;
      });
    }
  }

  // r1/r2自動推定（簡易版: 画像の中心から外周方向にグレースケール値の変化を見て推定）
  Future<void> _autoEstimateRadii() async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return;
    }
    setState(() {
      _isBusy = true;
    });
    try {
      final XFile file = await _cameraController!.takePicture();
      final bytes = await file.readAsBytes();
      final original = img.decodeImage(bytes);
      if (original == null) {
        return;
      }
      final gray = img.grayscale(original);
      final width = gray.width;
      final height = gray.height;
      final centerX = width ~/ 2;
      final centerY = height ~/ 2;
      final minSide = width < height ? width : height;
      // 8方向の平均輝度プロファイルを取得
      List<double> profile = List.filled(minSide ~/ 2, 0);
      int directions = 8;
      for (int d = 0; d < directions; d++) {
        double angle = 2 * 3.1415926535 * d / directions;
        for (int r = 0; r < profile.length; r++) {
          int x = (centerX + r * math.cos(angle)).round();
          int y = (centerY + r * math.sin(angle)).round();
          if (x >= 0 && x < width && y >= 0 && y < height) {
            var pixel = gray.getPixel(x, y);
            double luma = img.getLuminance(pixel).toDouble();
            profile[r] += luma;
          }
        }
      }
      for (int r = 0; r < profile.length; r++) {
        profile[r] /= directions;
      }
      // 輝度変化が大きい場所をr1/r2候補とする
      double maxDiff = 0;
      int r1 = (minSide * 0.2).toInt();
      int r2 = (minSide * 0.7).toInt();
      for (int r = 5; r < profile.length - 5; r++) {
        double diff = (profile[r] - profile[r - 5]).abs();
        if (diff > maxDiff) {
          maxDiff = diff;
          r1 = r;
        }
      }
      // r2は外周側の輝度変化最大点
      maxDiff = 0;
      for (int r = profile.length - 1; r > r1 + 10; r--) {
        double diff = (profile[r] - profile[r - 5]).abs();
        if (diff > maxDiff) {
          maxDiff = diff;
          r2 = r;
        }
      }
      setState(() {
        _r1Ratio = r1 / minSide;
        _r2Ratio = r2 / minSide;
      });
    } catch (e) {
      // 失敗時は何もしない
    } finally {
      setState(() {
        _isBusy = false;
      });
    }
  }

  Future<String?> _generateUnwrapImage({int shift = 0}) async {
    if (_cameraController == null || !_cameraController!.value.isInitialized) {
      return null;
    }
    final XFile file = await _cameraController!.takePicture();
    final bytes = await file.readAsBytes();
    final original = img.decodeImage(bytes);
    if (original == null) return null;
    final gray = img.grayscale(original);
    final contrast = img.adjustColor(gray, gamma: 0.7, contrast: 1.5);
    final tempDir = await getTemporaryDirectory();
    final centerX = (contrast.width * _centerXRatio).round();
    final centerY = (contrast.height * _centerYRatio).round();
    final minSide =
        contrast.width < contrast.height ? contrast.width : contrast.height;
    final r1 = (minSide * _r1Ratio).round();
    final r2 = (minSide * _r2Ratio).round();
    final unwrapHeight = r2 - r1;
    final unwrapWidth = 360;
    final unwrap = img.Image(width: unwrapWidth, height: unwrapHeight);
    for (int theta = 0; theta < unwrapWidth; theta++) {
      final angle =
          ((theta + shift) % unwrapWidth) * 2 * 3.1415926535 / unwrapWidth;
      for (int r = 0; r < unwrapHeight; r++) {
        final rr = r1 + r;
        final x = (centerX + rr * math.cos(angle)).round();
        final y = (centerY + rr * math.sin(angle)).round();
        if (x >= 0 && x < contrast.width && y >= 0 && y < contrast.height) {
          unwrap.setPixel(theta, r, contrast.getPixel(x, y));
        } else {
          unwrap.setPixelRgba(theta, r, 255, 255, 255, 255);
        }
      }
    }
    final flippedUnwrap = img.flipVertical(unwrap);
    // --- ここからファイル名一意化＆古いファイル削除 ---
    final now = DateTime.now();
    final fileName =
        'unwrap_${now.year.toString().padLeft(4, '0')}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}_${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}${now.millisecond.toString().padLeft(3, '0')}.jpg';
    final unwrapPath = '${tempDir.path}/$fileName';
    await File(unwrapPath).writeAsBytes(img.encodeJpg(flippedUnwrap));

    // tempDir内のunwrap_*.jpgを列挙し、2ファイルより多ければ古いものを削除
    final files =
        tempDir
            .listSync()
            .whereType<File>()
            .where(
              (f) => RegExp(
                r'unwrap_\d{8}_\d{9}\.jpg',
              ).hasMatch(f.path.split(Platform.pathSeparator).last),
            )
            .toList();
    if (files.length > 2) {
      files.sort((a, b) => b.path.compareTo(a.path)); // 新しい順
      for (int i = 2; i < files.length; i++) {
        try {
          files[i].deleteSync();
        } catch (_) {}
      }
    }
    return unwrapPath;
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(widget.title),
      ),
      body: Column(
        children: [
          if (_cameraController != null &&
              _cameraController!.value.isInitialized)
            AspectRatio(
              aspectRatio: _cameraController!.value.aspectRatio,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  final h = constraints.maxHeight;
                  final minSide = w < h ? w : h;
                  final centerX = w * _centerXRatio;
                  final centerY = h * _centerYRatio;
                  final r1 = minSide * _r1Ratio;
                  final r2 = minSide * _r2Ratio;
                  final maskRadius = minSide * (_maskRadiusRatio ?? 0.5);
                  return GestureDetector(
                    onPanUpdate: (details) {
                      setState(() {
                        _centerXRatio = ((centerX + details.delta.dx) / w)
                            .clamp(0.0, 1.0);
                        _centerYRatio = ((centerY + details.delta.dy) / h)
                            .clamp(0.0, 1.0);
                      });
                    },
                    onTapDown: (details) {
                      final local = details.localPosition;
                      setState(() {
                        _centerXRatio = (local.dx / w).clamp(0.0, 1.0);
                        _centerYRatio = (local.dy / h).clamp(0.0, 1.0);
                      });
                    },
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        CameraPreview(_cameraController!),
                        CustomPaint(
                          painter: _CircleGuidePainter(
                            centerX,
                            centerY,
                            r1,
                            r2,
                            maskRadius,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            )
          else
            const Center(child: CircularProgressIndicator()),
          Expanded(
            child: Scrollbar(
              thumbVisibility: true,
              child: SingleChildScrollView(
                padding: EdgeInsets.zero,
                child: Column(
                  children: [
                    // パラメータ・UI
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Radio<OcrMode>(
                          value: OcrMode.normal,
                          groupValue: _ocrMode,
                          onChanged: (v) {
                            setState(() {
                              _ocrMode = v!;
                              _recognizedText = '';
                              _unwrapImagePath = null;
                              _unwrapShift = 0;
                              _previewKey = UniqueKey();
                              _maskedImagePath = null;
                              _upperImagePath = null;
                              _lowerImagePath = null;
                            });
                          },
                        ),
                        const Text('通常パターン'),
                        Radio<OcrMode>(
                          value: OcrMode.unwrap,
                          groupValue: _ocrMode,
                          onChanged: (v) {
                            setState(() {
                              _ocrMode = v!;
                              _recognizedText = '';
                              _unwrapImagePath = null;
                              _unwrapShift = 0;
                              _previewKey = UniqueKey();
                              _maskedImagePath = null;
                              _upperImagePath = null;
                              _lowerImagePath = null;
                            });
                          },
                        ),
                        const Text('アンラップ'),
                      ],
                    ),
                    if (_ocrMode == OcrMode.normal) ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Radio<bool>(
                            value: false,
                            groupValue: _splitNormal,
                            onChanged: (v) {
                              setState(() {
                                _splitNormal = v!;
                              });
                            },
                          ),
                          const Text('分割しない'),
                          Radio<bool>(
                            value: true,
                            groupValue: _splitNormal,
                            onChanged: (v) {
                              setState(() {
                                _splitNormal = v!;
                              });
                            },
                          ),
                          const Text('上下分割'),
                        ],
                      ),
                    ],
                    if (_ocrMode == OcrMode.unwrap) ...[
                      Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text('r1'),
                              IconButton(
                                icon: const Icon(Icons.remove),
                                onPressed: () {
                                  setState(() {
                                    _r1Ratio = (_r1Ratio - 0.01).clamp(
                                      0.1,
                                      0.9,
                                    );
                                  });
                                },
                              ),
                              Expanded(
                                child: Slider(
                                  value: _r1Ratio,
                                  min: 0.1,
                                  max: 0.9,
                                  divisions: 80,
                                  label: _r1Ratio.toStringAsFixed(2),
                                  onChanged: (v) {
                                    setState(() {
                                      _r1Ratio = v;
                                      if (_linkR1R2) {
                                        _r2Ratio = (_r1Ratio + _r1r2Diff).clamp(
                                          0.1,
                                          0.9,
                                        );
                                      }
                                    });
                                  },
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.add),
                                onPressed: () {
                                  setState(() {
                                    _r1Ratio = (_r1Ratio + 0.01).clamp(
                                      0.1,
                                      0.9,
                                    );
                                  });
                                },
                              ),
                              Text('(${(_r1Ratio * 100).toStringAsFixed(0)}%)'),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text('r2'),
                              IconButton(
                                icon: const Icon(Icons.remove),
                                onPressed: () {
                                  setState(() {
                                    _r2Ratio = (_r2Ratio - 0.01).clamp(
                                      0.1,
                                      0.9,
                                    );
                                  });
                                },
                              ),
                              Expanded(
                                child: Slider(
                                  value: _r2Ratio,
                                  min: 0.1,
                                  max: 0.9,
                                  divisions: 80,
                                  label: _r2Ratio.toStringAsFixed(2),
                                  onChanged: (v) {
                                    setState(() {
                                      if (_linkR1R2) {
                                        _r2Ratio = (_r1Ratio + _r1r2Diff).clamp(
                                          0.1,
                                          0.9,
                                        );
                                      } else {
                                        _r2Ratio = v;
                                        _r1r2Diff = (_r2Ratio - _r1Ratio).clamp(
                                          0.01,
                                          0.8,
                                        );
                                      }
                                    });
                                  },
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.add),
                                onPressed: () {
                                  setState(() {
                                    _r2Ratio = (_r2Ratio + 0.01).clamp(
                                      0.1,
                                      0.9,
                                    );
                                  });
                                },
                              ),
                              Text('(${(_r2Ratio * 100).toStringAsFixed(0)}%)'),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text('中心X'),
                              Expanded(
                                child: Slider(
                                  value: _centerXRatio,
                                  min: 0.0,
                                  max: 1.0,
                                  divisions: 100,
                                  label: _centerXRatio.toStringAsFixed(2),
                                  onChanged: (v) {
                                    setState(() {
                                      _centerXRatio = v;
                                    });
                                  },
                                ),
                              ),
                              Text(
                                '(${(_centerXRatio * 100).toStringAsFixed(0)}%)',
                              ),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text('中心Y'),
                              Expanded(
                                child: Slider(
                                  value: _centerYRatio,
                                  min: 0.0,
                                  max: 1.0,
                                  divisions: 100,
                                  label: _centerYRatio.toStringAsFixed(2),
                                  onChanged: (v) {
                                    setState(() {
                                      _centerYRatio = v;
                                    });
                                  },
                                ),
                              ),
                              Text(
                                '(${(_centerYRatio * 100).toStringAsFixed(0)}%)',
                              ),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Text('マスク円半径'),
                              Expanded(
                                child: Slider(
                                  value: _maskRadiusRatio ?? 0.5,
                                  min: 0.1,
                                  max: 0.9,
                                  divisions: 80,
                                  label:
                                      '${((_maskRadiusRatio ?? 0.5) * 100).toStringAsFixed(0)}%',
                                  onChanged: (v) {
                                    setState(() {
                                      _maskRadiusRatio = v;
                                    });
                                  },
                                ),
                              ),
                              Text(
                                '(${((_maskRadiusRatio ?? 0.5) * 100).toStringAsFixed(0)}%)',
                              ),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              ElevatedButton(
                                onPressed: _isBusy ? null : _autoEstimateRadii,
                                child: const Text('自動推定'),
                              ),
                            ],
                          ),
                          if (_unwrapImagePath != null)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 4,
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text('アンラップ画像パス:'),
                                  SelectableText(
                                    _unwrapImagePath!,
                                    maxLines: 2,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.grey,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Checkbox(
                                value: _autoSelectBest,
                                onChanged: (v) {
                                  setState(() {
                                    _autoSelectBest = v ?? false;
                                  });
                                },
                              ),
                              const Text('両パターンから自動で精度の高い方を採用'),
                            ],
                          ),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Checkbox(
                                value: _linkR1R2,
                                onChanged: (v) {
                                  setState(() {
                                    _linkR1R2 = v ?? false;
                                    if (_linkR1R2) {
                                      _r2Ratio = (_r1Ratio + _r1r2Diff).clamp(
                                        0.1,
                                        0.9,
                                      );
                                    }
                                  });
                                },
                              ),
                              const Text('r1とr2を連動'),
                            ],
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(color: Colors.blue, width: 2),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _recognizedText,
                          style: const TextStyle(
                            fontSize: 16,
                            color: Colors.black,
                          ),
                        ),
                      ),
                    ),
                    if (_ocrMode == OcrMode.unwrap && _unwrapImagePath != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('アンラップ画像プレビュー:'),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 200,
                              child: Image.file(
                                File(_unwrapImagePath!),
                                key: _previewKey,
                                fit: BoxFit.contain,
                                errorBuilder:
                                    (context, error, stackTrace) =>
                                        const Text('画像の読み込みに失敗しました'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    if (_ocrMode == OcrMode.normal) ...[
                      if (!_splitNormal && _maskedImagePath != null) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('マスク画像プレビュー:'),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 200,
                                child: Image.file(
                                  File(_maskedImagePath!),
                                  fit: BoxFit.contain,
                                  errorBuilder:
                                      (context, error, stackTrace) =>
                                          const Text('画像の読み込みに失敗しました'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (_splitNormal &&
                          _upperImagePath != null &&
                          _lowerImagePath != null) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('上画像プレビュー:'),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 100,
                                child: Image.file(
                                  File(_upperImagePath!),
                                  fit: BoxFit.contain,
                                  errorBuilder:
                                      (context, error, stackTrace) =>
                                          const Text('画像の読み込みに失敗しました'),
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text('下画像プレビュー:'),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 100,
                                child: Image.file(
                                  File(_lowerImagePath!),
                                  fit: BoxFit.contain,
                                  errorBuilder:
                                      (context, error, stackTrace) =>
                                          const Text('画像の読み込みに失敗しました'),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                    const SizedBox(height: 16),
                    Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _isBusy ? null : _captureAndRecognize,
                          child: const Text('撮影してOCR'),
                        ),
                      ),
                    ),
                    if (_ocrMode == OcrMode.unwrap && _unwrapImagePath != null)
                      ElevatedButton(
                        onPressed:
                            _isBusy || _unwrapImagePath == null
                                ? null
                                : () async {
                                  setState(() {
                                    _isBusy = true;
                                  });
                                  try {
                                    final textRecognizer = TextRecognizer();
                                    final unwrapResult = await textRecognizer
                                        .processImage(
                                          InputImage.fromFilePath(
                                            _unwrapImagePath!,
                                          ),
                                        );
                                    await textRecognizer.close();
                                    setState(() {
                                      _recognizedText =
                                          '[アンラップ画像再OCR]\n${unwrapResult.text}';
                                    });
                                  } catch (e) {
                                    setState(() {
                                      _recognizedText =
                                          '再OCRエラー: \n${e.toString()}';
                                    });
                                  } finally {
                                    setState(() {
                                      _isBusy = false;
                                    });
                                  }
                                },
                        child: const Text('アンラップ画像で再OCR'),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_ocrMode == OcrMode.unwrap) ...[
                // --- アンラップ画像シフト量スライダー ---
                Row(
                  children: [
                    const Text('アンラップ画像シフト量'),
                    Expanded(
                      child: Slider(
                        value: _unwrapShift.toDouble(),
                        min: 0,
                        max: 359,
                        divisions: 36,
                        label: '$_unwrapShift°',
                        onChanged:
                            _isBusy
                                ? null
                                : (v) async {
                                  final shift = v.round();
                                  setState(() {
                                    _unwrapShift = shift;
                                    _isBusy = true;
                                  });
                                  final path = await _generateUnwrapImage(
                                    shift: shift,
                                  );
                                  setState(() {
                                    _unwrapImagePath = path;
                                    _isBusy = false;
                                  });
                                },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('$_unwrapShift°'),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CircleGuidePainter extends CustomPainter {
  final double cx, cy, r1, r2, maskRadius;
  _CircleGuidePainter(this.cx, this.cy, this.r1, this.r2, this.maskRadius);
  @override
  void paint(Canvas canvas, Size size) {
    final paint1 =
        Paint()
          ..color = const Color.fromARGB(128, 255, 0, 0)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
    final paint2 =
        Paint()
          ..color = const Color.fromARGB(128, 0, 0, 255)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
    final paint3 =
        Paint()
          ..color = const Color.fromARGB(128, 0, 255, 0)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
    canvas.drawCircle(Offset(cx, cy), r1, paint1);
    canvas.drawCircle(Offset(cx, cy), r2, paint2);
    if (maskRadius > 0) {
      canvas.drawCircle(Offset(cx, cy), maskRadius, paint3);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}
