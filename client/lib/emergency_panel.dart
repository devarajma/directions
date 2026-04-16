import 'package:flutter/material.dart';
import 'models/emergency_contact.dart';

class EmergencyPanel extends StatelessWidget {
  final DraggableScrollableController panelController;
  final TextEditingController userPhoneController;
  final ValueChanged<String> onSaveUserPhone;
  final VoidCallback onSendEmergencyAlerts;
  final VoidCallback onShowAddContactDialog;
  final List<EmergencyContact> contacts;
  final ValueChanged<int> onRemoveContact;

  const EmergencyPanel({
    super.key,
    required this.panelController,
    required this.userPhoneController,
    required this.onSaveUserPhone,
    required this.onSendEmergencyAlerts,
    required this.onShowAddContactDialog,
    required this.contacts,
    required this.onRemoveContact,
  });

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      controller: panelController,
      initialChildSize: 0.07,
      minChildSize: 0.07,
      maxChildSize: 0.90,
      snap: true,
      snapSizes: const [0.07, 0.50, 0.90],
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xF51A1A2E),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border.all(
              color: Colors.white.withAlpha(20), // using withAlpha for ~0.08
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withAlpha(128), // 0.5 opacity
                blurRadius: 30,
                spreadRadius: 5,
              ),
            ],
          ),
          child: ListView(
            controller: scrollController,
            padding: EdgeInsets.zero,
            children: [
              // ── drag handle + peek label ──────────────────────
              GestureDetector(
                onTap: () {
                  final current = panelController.size;
                  if (current <= 0.1) {
                    panelController.animateTo(
                      0.5,
                      duration: const Duration(milliseconds: 350),
                      curve: Curves.easeOut,
                    );
                  } else {
                    panelController.animateTo(
                      0.07,
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeIn,
                    );
                  }
                },
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, 10, 0, 8),
                  child: Column(
                    children: [
                      Center(
                        child: Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white.withAlpha(90), // ~0.35
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.keyboard_arrow_up,
                              color: Colors.white.withAlpha(100), // ~0.4
                              size: 16),
                          const SizedBox(width: 4),
                          Text(
                            "Emergency Panel",
                            style: TextStyle(
                                color: Colors.white.withAlpha(100),
                                fontSize: 11,
                                letterSpacing: 0.5),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // ── panel title ───────────────────────────────────
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  "Emergency Panel",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  "Manage contacts & send emergency alerts",
                  style: TextStyle(
                      color: Colors.white.withAlpha(128), // ~0.5
                      fontSize: 13),
                ),
              ),

              const SizedBox(height: 20),

              // ── My Phone Number ───────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: TextField(
                  controller: userPhoneController,
                  onChanged: onSaveUserPhone,
                  style: const TextStyle(color: Colors.white),
                  keyboardType: TextInputType.phone,
                  decoration: InputDecoration(
                    labelText: "My Phone Number",
                    labelStyle: TextStyle(color: Colors.white.withAlpha(153)), // ~0.6
                    prefixIcon: const Icon(Icons.smartphone, color: Colors.orangeAccent),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: Colors.white.withAlpha(51)), // ~0.2
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: Colors.orangeAccent),
                    ),
                  ),
                ),
              ),
              
              const SizedBox(height: 20),

              // ── SEND HELP button ──────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: onSendEmergencyAlerts,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 18),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Colors.red.shade700,
                            Colors.red.shade900,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(16),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.red.withAlpha(100), // ~0.4
                            blurRadius: 20,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.sos_rounded,
                              color: Colors.white, size: 28),
                          SizedBox(width: 10),
                          Text(
                            "SEND HELP",
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 2,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 24),

              // ── contacts header ───────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      "Emergency Contacts",
                      style: TextStyle(
                        color: Colors.white.withAlpha(204), // ~0.8
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    GestureDetector(
                      onTap: onShowAddContactDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: Colors.orangeAccent.withAlpha(38), // ~0.15
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                              color: Colors.orangeAccent.withAlpha(100)), // ~0.4
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.person_add,
                                color: Colors.orangeAccent, size: 16),
                            SizedBox(width: 6),
                            Text("Add",
                                style: TextStyle(
                                    color: Colors.orangeAccent,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 12),

              // ── contacts list ─────────────────────────────────
              if (contacts.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 20),
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(10), // ~0.04
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                          color: Colors.white.withAlpha(20)), // ~0.08
                    ),
                    child: Column(
                      children: [
                        Icon(Icons.people_outline,
                            color: Colors.white.withAlpha(51), // ~0.2
                            size: 40),
                        const SizedBox(height: 10),
                        Text(
                          "No emergency contacts yet",
                          style: TextStyle(
                              color: Colors.white.withAlpha(100), // ~0.4
                              fontSize: 14),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          "Tap 'Add' to add your first contact",
                          style: TextStyle(
                              color: Colors.white.withAlpha(64), // ~0.25
                              fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                )
              else
                ...List.generate(contacts.length, (i) {
                  final c = contacts[i];
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 4),
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withAlpha(13), // ~0.05
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                            color: Colors.white.withAlpha(20)), // ~0.08
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 4),
                        leading: Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.greenAccent.withAlpha(38), // ~0.15
                            shape: BoxShape.circle,
                          ),
                          child:
                              const Icon(Icons.sms, color: Colors.greenAccent, size: 20),
                        ),
                        title: Text(c.name,
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontSize: 15)),
                        subtitle: Text(c.number,
                            style: TextStyle(
                                color: Colors.white.withAlpha(128), // ~0.5
                                fontSize: 12)),
                        trailing: GestureDetector(
                          onTap: () => onRemoveContact(i),
                          child: Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.red.withAlpha(25), // ~0.1
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.delete_outline,
                                color: Colors.redAccent, size: 18),
                          ),
                        ),
                      ),
                    ),
                  );
                }),

              const SizedBox(height: 24),

              // ── info section ──────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.blue.withAlpha(15), // ~0.06
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                        color: Colors.blue.withAlpha(31)), // ~0.12
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          color: Colors.lightBlueAccent.withAlpha(179), // ~0.7
                          size: 20),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          "Fall detection is active. If a fall is detected, alerts will be sent after a 5-second countdown.",
                          style: TextStyle(
                            color: Colors.white.withAlpha(128), // ~0.5
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 30),
            ],
          ),
        );
      },
    );
  }
}
