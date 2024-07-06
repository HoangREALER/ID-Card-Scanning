import 'dart:convert';

import 'package:expandable/expandable.dart';
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'dart:async';
import 'dart:typed_data';

import 'package:dmrtd/dmrtd.dart';
import 'package:dmrtd/extensions.dart';
import 'package:flutter/services.dart';
import 'package:flutter_platform_widgets/flutter_platform_widgets.dart';
import 'package:intl/intl.dart';
import 'package:logging/logging.dart';

import 'package:mrtdeg/mrtd.dart';

class ScanIdCard extends StatefulWidget {
  final Mrz mrz;

  ScanIdCard({required this.mrz});

  @override
  // ignore: library_private_types_in_public_api
  _MrtdHomePageState createState() => _MrtdHomePageState();
}

class _MrtdHomePageState extends State<ScanIdCard> {
  var _alertMessage = "";
  final _log = Logger("mrtdeg.app");
  var _isNfcAvailable = false;
  var _isReading = false;
  // final _mrzData = GlobalKey<FormState>();

  // mrz data
  final _docNumber = TextEditingController();
  final _dob = TextEditingController(); // date of birth
  final _doe = TextEditingController(); // date of doc expiry

  MrtdData? _mrtdData;
  final _mrtdDataDump = {};

  final NfcProvider _nfc = NfcProvider();
  // ignore: unused_field
  late Timer _timerStateUpdater;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    _initPlatformState();

    // Update platform state every 3 sec
    _timerStateUpdater = Timer.periodic(Duration(seconds: 3), (Timer t) {
      _initPlatformState();
    });
  }

  // Platform messages are asynchronous, so we initialize in an async method.
  Future<void> _initPlatformState() async {
    bool isNfcAvailable;
    try {
      NfcStatus status = await NfcProvider.nfcStatus;
      isNfcAvailable = status == NfcStatus.enabled;
    } on PlatformException {
      isNfcAvailable = false;
    }

    // If the widget was removed from the tree while the asynchronous platform
    // message was in flight, we want to discard the reply rather than calling
    // setState to update our non-existent appearance.
    if (!mounted) return;

    if (_isNfcAvailable == isNfcAvailable) {
      return;
    }

    setState(() {
      _isNfcAvailable = isNfcAvailable;
    });
  }

  DateTime? _getDOBDate() {
    if (_dob.text.isEmpty) {
      return null;
    }
    return DateFormat.yMd().parse(_dob.text);
  }

  DateTime? _getDOEDate() {
    if (_doe.text.isEmpty) {
      return null;
    }
    return DateFormat.yMd().parse(_doe.text);
  }

  Future<String?> _pickDate(BuildContext context, DateTime firstDate,
      DateTime initDate, DateTime lastDate) async {
    final locale = Localizations.localeOf(context);
    final DateTime? picked = await showDatePicker(
        context: context,
        firstDate: firstDate,
        initialDate: initDate,
        lastDate: lastDate,
        locale: locale);

    if (picked != null) {
      return DateFormat.yMd().format(picked);
    }
    return null;
  }

  BigInt bytes2bigint(Uint8List bytes) {
    BigInt result = BigInt.zero;

    for (final byte in bytes) {
      // reading in big-endian, so we essentially concat the new byte to the end
      result = (result << 8) | BigInt.from(byte & 0xff);
    }
    return result;
  }

  void _readMRTD() async {
    try {
      setState(() {
        _mrtdData = null;
        _alertMessage = "Waiting for Passport tag ...";
        _isReading = true;
      });

      await _nfc.connect(
          iosAlertMessage: "Hold your phone near Biometric Passport");
      final passport = Passport(_nfc);

      setState(() {
        _alertMessage = "Reading Passport ...";
      });
      var skipPACE = true;
      _nfc.setIosAlertMessage("Trying to read EF.CardAccess ...");
      final mrtdData = MrtdData();
      try {
        mrtdData.cardAccess = await passport.readEfCardAccess();
        _log.debug("access: ${mrtdData.cardAccess}");
        _log.debug(mrtdData.cardAccess!.toBytes().hex());
        skipPACE = false;
      } on PassportError {
        _log.error("Error reading card access");
        //if (e.code != StatusWord.fileNotFound) rethrow;
      }
      // _nfc.setIosAlertMessage("Trying to read EF.CardSecurity ...");
      // try {
      //   mrtdData.cardSecurity = await passport.readEfCardSecurity();
      //   _log.debug("CardSec: ${mrtdData.cardSecurity}");
      // } on PassportError {
      //   _log.error("Error reading card security");
      //   //if (e.code != StatusWord.fileNotFound) rethrow;
      // }
      _nfc.setIosAlertMessage("Initiating session ...");
      if (skipPACE == false) {
        try {
          var data = mrtdData.cardAccess;
          var securityInfos = getSecurityInfos(data);
          _log.debug(
              "Starting Password Authenticated Connection Establishment (PACE)");
          // _log.debug("Starting PACE SM key establishment ...");
          final paceKeySeed =
              PACEKeys(widget.mrz.id, widget.mrz.birthday, widget.mrz.expiry);
          await passport.startSessionPACE(paceKeySeed, securityInfos);
        } on Exception catch (e) {
          skipPACE = true;
          _log.debug(e);
          _log.debug("PACE Failed - falling back to BAC");
        }
      }
      if (skipPACE) {
        final bacKeySeed =
            DBAKeys(widget.mrz.id, widget.mrz.birthday, widget.mrz.expiry);
        await passport.startSessionBAC(bacKeySeed);
      }
      _nfc.setIosAlertMessage(formatProgressMsg("Reading EF.COM ...", 0));
      mrtdData.com = await passport.readEfCOM();
      _mrtdDataDump["com"] = base64Encode(mrtdData.com!.toBytes());

      _nfc.setIosAlertMessage(formatProgressMsg("Reading Data Groups ...", 20));

      if (mrtdData.com!.dgTags.contains(EfDG1.TAG)) {
        mrtdData.dg1 = await passport.readEfDG1();
        _mrtdDataDump["dg1"] = base64Encode(mrtdData.dg1!.toBytes());
      }

      if (mrtdData.com!.dgTags.contains(EfDG2.TAG)) {
        mrtdData.dg2 = await passport.readEfDG2();
        _mrtdDataDump["dg2"] = base64Encode(mrtdData.dg2!.toBytes());
      }

      // To read DG3 and DG4 session has to be established with CVCA certificate (not supported).
      // if(mrtdData.com!.dgTags.contains(EfDG3.TAG)) {
      //   mrtdData.dg3 = await passport.readEfDG3();
      // }

      // if(mrtdData.com!.dgTags.contains(EfDG4.TAG)) {
      //   mrtdData.dg4 = await passport.readEfDG4();
      // }

      if (mrtdData.com!.dgTags.contains(EfDG5.TAG)) {
        mrtdData.dg5 = await passport.readEfDG5();
        _mrtdDataDump["dg5"] = base64Encode(mrtdData.dg5!.toBytes());
      }

      if (mrtdData.com!.dgTags.contains(EfDG6.TAG)) {
        mrtdData.dg6 = await passport.readEfDG6();
        _mrtdDataDump["dg6"] = base64Encode(mrtdData.dg6!.toBytes());
      }

      if (mrtdData.com!.dgTags.contains(EfDG7.TAG)) {
        mrtdData.dg7 = await passport.readEfDG7();
        _mrtdDataDump["dg7"] = base64Encode(mrtdData.dg7!.toBytes());
      }

      if (mrtdData.com!.dgTags.contains(EfDG8.TAG)) {
        mrtdData.dg8 = await passport.readEfDG8();
        _mrtdDataDump["dg8"] = base64Encode(mrtdData.dg8!.toBytes());
      }

      if (mrtdData.com!.dgTags.contains(EfDG9.TAG)) {
        mrtdData.dg9 = await passport.readEfDG9();
        _mrtdDataDump["dg9"] = base64Encode(mrtdData.dg9!.toBytes());
      }

      if (mrtdData.com!.dgTags.contains(EfDG10.TAG)) {
        mrtdData.dg10 = await passport.readEfDG10();
        _mrtdDataDump["dg10"] = base64Encode(mrtdData.dg10!.toBytes());
      }

      if (mrtdData.com!.dgTags.contains(EfDG11.TAG)) {
        mrtdData.dg11 = await passport.readEfDG11();
        _mrtdDataDump["dg11"] = base64Encode(mrtdData.dg11!.toBytes());
      }

      if (mrtdData.com!.dgTags.contains(EfDG12.TAG)) {
        mrtdData.dg12 = await passport.readEfDG12();
        _mrtdDataDump["dg12"] = base64Encode(mrtdData.dg12!.toBytes());
      }

      if (mrtdData.com!.dgTags.contains(EfDG13.TAG)) {
        mrtdData.dg13 = await passport.readEfDG13();
        _mrtdDataDump["dg13"] = base64Encode(mrtdData.dg13!.toBytes());
      }

      if (mrtdData.com!.dgTags.contains(EfDG14.TAG)) {
        mrtdData.dg14 = await passport.readEfDG14();
        _mrtdDataDump["dg14"] = base64Encode(mrtdData.dg14!.toBytes());
      }

      if (mrtdData.com!.dgTags.contains(EfDG15.TAG)) {
        mrtdData.dg15 = await passport.readEfDG15();
        _nfc.setIosAlertMessage(formatProgressMsg("Doing AA ...", 60));
        mrtdData.authData = Uint8List.fromList([0, 1, 2, 3, 4, 5, 6, 7]);
        _mrtdDataDump["authData"] = base64Encode(mrtdData.authData!);
        mrtdData.aaSig = await passport.activeAuthenticate(mrtdData.authData!);
        _mrtdDataDump["aaSig"] = base64Encode(mrtdData.aaSig!);
      }

      if (mrtdData.com!.dgTags.contains(EfDG16.TAG)) {
        mrtdData.dg16 = await passport.readEfDG16();
        _mrtdDataDump["dg16"] = base64Encode(mrtdData.dg16!.toBytes());
      }

      _nfc.setIosAlertMessage(formatProgressMsg("Reading EF.SOD ...", 80));
      mrtdData.sod = await passport.readEfSOD();
      _mrtdDataDump["sod"] = base64Encode(mrtdData.sod!.toBytes());

      setState(() {
        _mrtdData = mrtdData;
      });

      setState(() {
        _alertMessage = "";
      });

      _scrollController.animateTo(300.0,
          duration: Duration(milliseconds: 500), curve: Curves.ease);
    } on Exception catch (e) {
      final se = e.toString().toLowerCase();
      String alertMsg = "An error has occurred while reading Passport!";
      if (e is PassportError) {
        if (se.contains("security status not satisfied")) {
          alertMsg =
              "Failed to initiate session with passport.\nCheck input data!";
        }
        _log.error("PassportError: ${e.message}");
      } else {
        _log.error(
            "An exception was encountered while trying to read Passport: $e");
      }

      if (se.contains('timeout')) {
        alertMsg = "Timeout while waiting for Passport tag";
      } else if (se.contains("tag was lost")) {
        alertMsg = "Tag was lost. Please try again!";
      } else if (se.contains("invalidated by user")) {
        alertMsg = "";
      }

      setState(() {
        _alertMessage = alertMsg;
      });
    } finally {
      if (_alertMessage.isNotEmpty) {
        await _nfc.disconnect(iosErrorMessage: _alertMessage);
      } else {
        await _nfc.disconnect(
            iosAlertMessage: formatProgressMsg("Finished", 100));
      }
      setState(() {
        _isReading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PlatformProvider(
        builder: (BuildContext context) => _buildPage(context));
  }

  bool _disabledInput() {
    return _isReading || !_isNfcAvailable;
  }

  Widget _makeMrtdDataWidget(
      {required String header,
      required String collapsedText,
      required dataText}) {
    return ExpandablePanel(
        theme: const ExpandableThemeData(
          headerAlignment: ExpandablePanelHeaderAlignment.center,
          tapBodyToCollapse: true,
          hasIcon: true,
          iconColor: Colors.red,
        ),
        header: Text(header),
        collapsed: Text(collapsedText,
            softWrap: true, maxLines: 2, overflow: TextOverflow.ellipsis),
        expanded: Container(
            padding: const EdgeInsets.all(18),
            color: Color.fromARGB(255, 239, 239, 239),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PlatformTextButton(
                    child: Text('Copy'),
                    onPressed: () =>
                        Clipboard.setData(ClipboardData(text: dataText)),
                    padding: const EdgeInsets.all(8),
                  ),
                  SelectableText(dataText, textAlign: TextAlign.left)
                ])));
  }

  List<Widget> _mrtdDataWidgets() {
    List<Widget> list = [];
    if (_mrtdData == null) return list;

    if (_mrtdData!.cardAccess != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.CardAccess',
          collapsedText: '',
          dataText:
              '${_mrtdData!.cardAccess!.toBytes().hex()}\n\n${formatCardAccess(_mrtdData!.cardAccess!)}'));
    }

    if (_mrtdData!.cardSecurity != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.CardSecurity',
          collapsedText: '',
          dataText: _mrtdData!.cardSecurity!.toBytes().hex()));
    }

    if (_mrtdData!.sod != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.SOD',
          collapsedText: '',
          dataText: "${_mrtdData!.sod!.toBytes().hex()}\n\nverify result: ${verify_sod(_mrtdData!)}"));
    }

    if (_mrtdData!.com != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.COM',
          collapsedText: '',
          dataText: formatEfCom(_mrtdData!.com!)));
    }

    if (_mrtdData!.dg1 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG1',
          collapsedText: '',
          dataText: '${_mrtdData!.dg1!.toBytes().hex()}\n\n Data\n\n${formatMRZ(_mrtdData!.dg1!.mrz)}'));
    }

    if (_mrtdData!.dg2 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG2',
          collapsedText: '',
          dataText: _mrtdData!.dg2!.toBytes().hex()));
      list.add(formatDG2(_mrtdData!.dg2!));
    }

    if (_mrtdData!.dg3 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG3',
          collapsedText: '',
          dataText: _mrtdData!.dg3!.toBytes().hex()));
    }

    if (_mrtdData!.dg4 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG4',
          collapsedText: '',
          dataText: _mrtdData!.dg4!.toBytes().hex()));
    }

    if (_mrtdData!.dg5 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG5',
          collapsedText: '',
          dataText: _mrtdData!.dg5!.toBytes().hex()));
    }

    if (_mrtdData!.dg6 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG6',
          collapsedText: '',
          dataText: _mrtdData!.dg6!.toBytes().hex()));
    }

    if (_mrtdData!.dg7 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG7',
          collapsedText: '',
          dataText: _mrtdData!.dg7!.toBytes().hex()));
    }

    if (_mrtdData!.dg8 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG8',
          collapsedText: '',
          dataText: _mrtdData!.dg8!.toBytes().hex()));
    }

    if (_mrtdData!.dg9 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG9',
          collapsedText: '',
          dataText: _mrtdData!.dg9!.toBytes().hex()));
    }

    if (_mrtdData!.dg10 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG10',
          collapsedText: '',
          dataText: _mrtdData!.dg10!.toBytes().hex()));
    }

    if (_mrtdData!.dg11 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG11',
          collapsedText: '',
          dataText: _mrtdData!.dg11!.toBytes().hex()));
    }

    if (_mrtdData!.dg12 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG12',
          collapsedText: '',
          dataText: _mrtdData!.dg12!.toBytes().hex()));
    }

    if (_mrtdData!.dg13 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG13',
          collapsedText: '',
          dataText: '${_mrtdData!.dg13!.toBytes().hex()}\n\n${formatDG13(_mrtdData!.dg13!)}'));
    }

    if (_mrtdData!.dg14 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG14',
          collapsedText: '',
          dataText: _mrtdData!.dg14!.toBytes().hex()));
    }

    if (_mrtdData!.dg15 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG15',
          collapsedText: '',
          dataText: '${_mrtdData!.dg14!.toBytes().hex()}\n\nInformation:\n${formatDG15(_mrtdData!.dg15!)}'));
    }

    if (_mrtdData!.aaSig != null) {
      final status = verify_active_auth(
          _mrtdData!.dg15!, _mrtdData!.aaSig!, _mrtdData!.authData!);

      list.add(_makeMrtdDataWidget(
          header: 'Active Authentication signature',
          collapsedText: '',
          dataText: "verify result: $status"));
    }

    if (_mrtdData!.dg16 != null) {
      list.add(_makeMrtdDataWidget(
          header: 'EF.DG16',
          collapsedText: '',
          dataText: _mrtdData!.dg16!.toBytes().hex()));
    }

    return list;
  }

  Map mrtdDump({bool excludeDg2 = false}) {
    final tmp = _mrtdDataDump.map((key, value) => MapEntry(key, value));
    tmp.removeWhere((key, value) => (excludeDg2 && key == "dg2") || (!excludeDg2 && key != "dg2"));
    return tmp;
  }

  PlatformScaffold _buildPage(BuildContext context) => PlatformScaffold(
      appBar: PlatformAppBar(title: Text('Em Hoàng\'s ID card verifier')),
      iosContentPadding: false,
      iosContentBottomPadding: false,
      body: Material(
          child: SafeArea(
              child: Padding(
                  padding: EdgeInsets.all(8.0),
                  child: SingleChildScrollView(
                      controller: _scrollController,
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            SizedBox(height: 20),
                            Row(children: <Widget>[
                              Text('NFC available:',
                                  style: TextStyle(
                                      fontSize: 18.0,
                                      fontWeight: FontWeight.bold)),
                              SizedBox(width: 4),
                              Text(_isNfcAvailable ? "Yes" : "No",
                                  style: TextStyle(fontSize: 18.0))
                            ]),
                            SizedBox(height: 40),
                            // _buildForm(context),
                            SizedBox(height: 20),
                            TextButton(
                              // btn Read MRTD
                              onPressed: _readMRTD,
                              child: PlatformText(
                                  _isReading ? 'Reading ...' : 'Read Passport'),
                            ),
                            SizedBox(height: 4),
                            Text(_alertMessage,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                    fontSize: 15.0,
                                    fontWeight: FontWeight.bold)),
                            SizedBox(height: 15),
                            Padding(
                              padding: EdgeInsets.all(8.0),
                              child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: <Widget>[
                                    Text(
                                        _mrtdData != null
                                            ? "Passport Data:"
                                            : "",
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                            fontSize: 15.0,
                                            fontWeight: FontWeight.bold)),
                                    Padding(
                                        padding: EdgeInsets.only(
                                            left: 16.0, top: 8.0, bottom: 8.0),
                                        child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: _mrtdDataWidgets())),
                                    Column(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                            ElevatedButton(
                                              onPressed: () async {
                                                try {
                                                  if (_mrtdData == null) return;
                                                  final data = mrtdDump(excludeDg2: true);
                                                  _log.debug("Json dump: ${jsonEncode(data)}");
                                                  await Clipboard.setData(
                                                      ClipboardData(text: jsonEncode(data))
                                                  );
                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                    SnackBar(content: Text('Copied to Clipboard!')),
                                                  );
                                                } catch (e) {
                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                    SnackBar(content: Text('Failed to copy to clipboard.')),
                                                  );
                                                  _log.error(e);
                                                }
                                                  
                                              }, 
                                              child: Text('Copy dump to json (without dg2)')
                                            ),
                                            ElevatedButton(
                                              onPressed: () async {
                                                try {
                                                  if (_mrtdData == null) return;
                                                  final data = mrtdDump(excludeDg2: false);
                                                  _log.debug("Json dump: ${jsonEncode(data)}");
                                                  await Clipboard.setData(
                                                      ClipboardData(text: jsonEncode(data))
                                                  );
                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                    SnackBar(content: Text('Copied to Clipboard!')),
                                                  );
                                                } catch (e) {
                                                  ScaffoldMessenger.of(context).showSnackBar(
                                                    SnackBar(content: Text('Failed to copy to clipboard.')),
                                                  );
                                                  _log.error(e);
                                                }
                                                  
                                              }, 
                                              child: Text('Copy dump to json (only dg2)')
                                            ),
                                      ],
                                    )
                                  ]),
                            ),
                          ]))))));

  /* Padding _buildForm(BuildContext context) {
    return Padding(
        padding: EdgeInsets.symmetric(vertical: 8.0, horizontal: 30.0),
        child: Form(
          key: _mrzData,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              TextFormField(
                enabled: !_disabledInput(),
                controller: _docNumber,
                decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Passport number',
                    fillColor: Colors.white),
                inputFormatters: <TextInputFormatter>[
                  FilteringTextInputFormatter.allow(RegExp(r'[A-Z0-9]+')),
                  LengthLimitingTextInputFormatter(14)
                ],
                textInputAction: TextInputAction.done,
                textCapitalization: TextCapitalization.characters,
                autofocus: true,
                validator: (value) {
                  return null;
                  if (value?.isEmpty ?? false) {
                    return 'Please enter passport number';
                  }
                  return null;
                },
              ),
              SizedBox(height: 12),
              TextFormField(
                  enabled: !_disabledInput(),
                  controller: _dob,
                  decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Date of Birth',
                      fillColor: Colors.white),
                  autofocus: false,
                  validator: (value) {
                    return null;
                    if (value?.isEmpty ?? false) {
                      return 'Please select Date of Birth';
                    }
                    return null;
                  },
                  onTap: () async {
                    FocusScope.of(context).requestFocus(FocusNode());
                    // Can pick date which dates 15 years back or more
                    final now = DateTime.now();
                    final firstDate =
                        DateTime(now.year - 90, now.month, now.day);
                    final lastDate =
                        DateTime(now.year - 15, now.month, now.day);
                    final initDate = _getDOBDate();
                    final date = await _pickDate(
                        context, firstDate, initDate ?? lastDate, lastDate);

                    FocusScope.of(context).requestFocus(FocusNode());
                    if (date != null) {
                      _dob.text = date;
                    }
                  }),
              SizedBox(height: 12),
              TextFormField(
                  enabled: !_disabledInput(),
                  controller: _doe,
                  decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      labelText: 'Date of Expiry',
                      fillColor: Colors.white),
                  autofocus: false,
                  validator: (value) {
                    return null;
                    if (value?.isEmpty ?? false) {
                      return 'Please select Date of Expiry';
                    }
                    return null;
                  },
                  onTap: () async {
                    FocusScope.of(context).requestFocus(FocusNode());
                    // Can pick date from tomorrow and up to 10 years
                    final now = DateTime.now();
                    final firstDate =
                        DateTime(now.year, now.month, now.day + 1);
                    final lastDate =
                        DateTime(now.year + 10, now.month + 6, now.day);
                    final initDate = _getDOEDate();
                    final date = await _pickDate(
                        context, firstDate, initDate ?? firstDate, lastDate);

                    FocusScope.of(context).requestFocus(FocusNode());
                    if (date != null) {
                      _doe.text = date;
                    }
                  })
            ],
          ),
        ));
  } */
}
