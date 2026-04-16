import 'package:background_sms/background_sms.dart';

void main() async {
  bool? simSupport = await BackgroundSms.isSupportCustomSim;
  await BackgroundSms.sendMessage(phoneNumber: "123", message: "m", simSlot: 1);
}
