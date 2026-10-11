
/// The specific incidents a citizen can report to each agency, grouped the way
/// each agency classifies them. Shown in the picker after choosing a card.
class IncidentCategory {
  final String name;
  final List<String> incidents;
  const IncidentCategory(this.name, this.incidents);
}

class IncidentCatalog {
  static const Map<String, List<IncidentCategory>> byAgency = {
    'BFP': [
      IncidentCategory('Fire Incidents', [
        'Structural Fire (Residential)',
        'Structural Fire (Commercial or Industrial)',
        'Structural Fire (High-rise, School or Hospital)',
        'Vehicular Fire',
        'Maritime or Vessel Fire',
        'Aircraft Fire or Airport Ground Incident',
        'Forest, Grass or Brush Fire',
        'Electrical or Transformer Fire',
        'Rubbish, Garbage or Dumpster Fire',
      ]),
      IncidentCategory('Hazardous Materials and Gas', [
        'LPG Leak or Fire',
        'Chemical Spill or Leak',
        'Industrial or Gas Explosion',
        'HAZMAT Emergency',
      ]),
      IncidentCategory('Technical Search and Rescue', [
        'Road Crash Extrication',
        'Collapsed Structure Rescue',
        'Confined Space Rescue',
        'High-Angle or Rope Rescue',
        'Water Rescue or Drowning',
      ]),
      IncidentCategory('Emergency Medical Services', [
        'Medical Emergency (Cardiac, Respiratory, Stroke, Seizure)',
        'Trauma Injury (Burns, Fractures, Cuts)',
        'Mass Casualty Incident (MCI)',
      ]),
      IncidentCategory('Special Incidents', [
        'Suspected Arson',
        'Bomb or Explosion Damage',
        'False or Unintended Alarm',
      ]),
    ],
    'CDRRMO': [
      IncidentCategory('Natural Disasters and Weather', [
        'Typhoon or Tropical Storm Damage',
        'Flash Flood or Urban Flooding',
        'Landslide, Mudslide or Soil Erosion',
        'Earthquake Damage',
        'Volcanic Ashfall or Eruption Impact',
        'Storm Surge or High-Tide Flooding',
      ]),
      IncidentCategory('Emergency Medical and Trauma', [
        'Road Crash (First Aid and Transport)',
        'Medical Emergency (Asthma, Hypertension, Cardiac Arrest, Fainting)',
        'Crime-Related Trauma (Gunshot, Stabbing, Assault)',
        'Mass Casualty Incident (MCI)',
        'Heat Stroke or Dehydration',
      ]),
      IncidentCategory('Search, Rescue and Retrieval', [
        'Water Search and Rescue (WASAR) or Drowning',
        'Urban Search and Rescue (USAR) or Structure Collapse',
        'Mountain Rescue or Missing Person',
        'Fallen Tree Blocking Road',
      ]),
      IncidentCategory('Public Safety and Environment', [
        'Hazardous Chemical Leak or Toxic Gas',
        'Dam or River Overflow and Evacuation',
        'Animal Control or Venomous Snake',
        'Structural Fire Assist',
      ]),
    ],
    'PNP': [
      IncidentCategory('Crimes Against Persons', [
        'Homicide or Murder',
        'Physical Injury or Assault (Stabbing, Mauling)',
        'Shooting or Gunfire',
        'Kidnapping or Illegal Detention',
        'Sexual Assault or Rape',
        'Domestic Violence (VAWC)',
        'Child Abuse or Human Trafficking',
      ]),
      IncidentCategory('Crimes Against Property', [
        'Robbery',
        'Theft, Snatching or Pickpocketing',
        'Carnapping (Motorcycle or Vehicle Theft)',
        'Swindling or Estafa',
        'Vandalism or Malicious Mischief',
      ]),
      IncidentCategory('Traffic and Vehicular', [
        'Road Traffic Collision',
        'Hit-and-Run',
        'Driving Under the Influence (DUI)',
        'Traffic Obstruction or Disturbance',
      ]),
      IncidentCategory('Illegal Activities', [
        'Illegal Drug Activity (RA 9165)',
        'Illegal Firearms or Explosives (RA 10591)',
        'Illegal Gambling',
        'Cybercrime (Online Scam, Identity Theft, Harassment)',
      ]),
      IncidentCategory('Public Order and Safety', [
        'Public Disturbance, Drunkenness or Brawl',
        'Trespassing or Illegal Entry',
        'Threat or Extortion',
        'Bomb Threat or Suspicious Device',
        'Riot or Unlawful Assembly',
      ]),
      IncidentCategory('Other Reports', [
        'Missing Person or Runaway',
        'Found Dead Body or Unattended Death',
        'Drowning Incident',
        'Suicide or Self-Harm',
        'Fire Incident (Police Report)',
      ]),
    ],
  };

  static const notSure = 'Not sure';
  static const maxPicks = 5;

  /// "BFP: Vehicular Fire". The agency before the colon decides routing,
  /// not words in the incident name.
  static String label(String agency, String incident) => '$agency: $incident';

  /// One agency's list.
  static List<IncidentSection> sectionsFor(String agency) => [
        for (final c in byAgency[agency] ?? const <IncidentCategory>[])
          IncidentSection(c.name, [for (final i in c.incidents) IncidentOption(i, i)]),
      ];

  /// General Emergency: every agency's list, each incident tagged with its agency.
  static List<IncidentSection> allSections() => [
        for (final e in byAgency.entries)
          for (final c in e.value)
            IncidentSection('${c.name} · ${e.key}', [
              for (final i in c.incidents) IncidentOption(label(e.key, i), i, agency: e.key),
            ]),
      ];

  /// What a card's picks are saved as on the report:
  ///   agency card      -> "BFP: Vehicular Fire; LPG Leak or Fire"   (sent to BFP)
  ///   General Emergency -> "General Emergency (BFP: Vehicular Fire; CDRRMO: Flash Flood)"
  ///                        (sent to the EOC only; the agencies are details for it)
  static String format(String card, Set<String> picks, {required bool general}) {
    if (general) {
      final details = picks.where((p) => p != notSure);
      return details.isEmpty ? card : '$card (${details.join('; ')})';
    }
    return label(card, picks.join('; '));
  }

  /// A report's type is one part per card, joined with ' · ' (see the report form).
  static List<String> parts(String incType) => incType.split(' · ');

  /// The cards on [incType] the reporter wasn't sure about: an agency ('BFP' for
  /// "BFP: Not sure") or 'General Emergency' (picked with no incidents).
  static List<String> undecided(String incType) => [
        for (final p in parts(incType))
          if (p.trim() == 'General Emergency')
            'General Emergency'
          else if (RegExp(r'^(BFP|PNP|CDRRMO): Not sure$').hasMatch(p.trim()))
            p.trim().split(':').first,
      ];

  /// [incType] with the undecided [card] replaced by what staff chose.
  static String decide(String incType, String card, Set<String> picks) {
    final general = card == 'General Emergency';
    final old = general ? 'General Emergency' : '$card: $notSure';
    final chosen = format(card, picks, general: general);
    return [for (final p in parts(incType)) p.trim() == old ? chosen : p].join(' · ');
  }

  /// Short text for the card once something is picked.
  static String summary(Set<String> picks) {
    if (picks.length == 1) return picks.first.replaceFirst(RegExp(r'^(BFP|PNP|CDRRMO): '), '');
    return '${picks.length} incidents';
  }
}

class IncidentSection {
  final String title;
  final List<IncidentOption> options;
  const IncidentSection(this.title, this.options);
}

class IncidentOption {
  final String value; // what is saved
  final String text; // what is shown
  final String? agency; // shown as a tag in the General Emergency list
  const IncidentOption(this.value, this.text, {this.agency});
}
