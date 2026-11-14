<p align="center">
  <img src="build/PCDoctor.png" width="96" alt="Logo PC Doctor">
</p>

<h1 align="center">PC Doctor</h1>

<p align="center">
  Une application Windows gratuite pour comprendre pourquoi votre PC rame ou plante, et régler le problème.
</p>

<p align="center">
  <a href="https://github.com/doninj/pc-doctor/releases/latest/download/PC-Doctor.exe"><b>⬇ Télécharger PC Doctor.exe</b></a>
  &nbsp;·&nbsp;
  <a href="../../releases">Toutes les versions</a>
</p>

---

## Ce que fait PC Doctor

| Page | Contenu |
|---|---|
| **Diagnostic** | Score de santé sur 100, processeur, RAM, disque, temps depuis l'allumage, et la liste des problèmes trouvés avec un bouton pour chacun. |
| **Solutions** | Solutions aux plantages, classées selon ce qui a été détecté (RAM/EXPO, températures, alimentation, pilote graphique, BIOS…). Beaucoup s'appliquent en un clic depuis l'appli. |
| **Boîte noire** | Enregistre l'état du PC toutes les 2 s (température et consommation GPU, processeur, RAM, programme utilisé) depuis la zone de notification. Après une coupure : courbes des 5 minutes précédentes et verdict (surchauffe, pic de consommation, PC au repos…). Alertes Windows si la carte graphique chauffe trop ou si la RAM sature. |
| **Pilotes** | Mises à jour de pilotes disponibles sur Windows Update (cocher, puis installer), pilote de la carte graphique, périphériques en erreur, pilotes anciens. |
| **Logiciels** | Mise à jour de tous les logiciels en un clic (ou un par un) avec winget. |
| **Performances** | Carte graphique NVIDIA en direct (température, consommation, fréquence) avec la température max enregistrée, limite de puissance réglable, état de la RAM (EXPO/XMP activé ou non), logiciels d'overclocking, mode d'alimentation, **santé des disques** (température, usure des SSD, erreurs, heures d'utilisation). |
| **Réseau** | Test de ping, gigue et pertes vers la box et Internet, vitesse DNS, et diagnostic (Wi-Fi, box ou fournisseur d'accès). |
| **Démarrage** | Programmes lancés avec Windows, avec un conseil pour chacun (désactivable, au choix, à garder) et un bouton Activer/Désactiver. |
| **Processus** | Ce qui consomme la RAM et le processeur, regroupé par programme. |
| **Plantages** | Écrans bleus, coupures nettes, logiciels qui plantent et erreurs disque des 30 derniers jours. |
| **Espace disque** | Quels dossiers et fichiers prennent le plus de place (navigation par double-clic, plus gros fichiers, répartition par type). |
| **Nettoyage** | Fichiers temporaires, caches, corbeille : combien de place on peut récupérer, et nettoyage en un clic. |
| **Paramètres** | Thème clair / sombre, mise à jour automatique de PC Doctor (vérifiée par empreinte SHA-256), widget au démarrage. |
| **Widget** | Petite fenêtre de bureau translucide : utilisation et température du processeur, de la carte graphique, de la RAM et du SSD en direct. Compact par défaut, taille, opacité, premier plan, détails et historique au clic droit. |

Rien n'est modifié sans confirmation. Les réglages (démarrage, limite de puissance, démarrage rapide…) sont réversibles.

Modes sans fenêtre principale :
- `"PC Doctor.exe" --widget` : le widget seul.
- `"PC Doctor.exe" --monitor` : la boîte noire seule (icône près de l'horloge).

> Température du processeur dans le widget : Windows ne la fournit pas pour tous les processeurs (notamment AMD Ryzen). Elle s'affiche automatiquement si **Core Temp** ou **HWiNFO** (option « Shared Memory Support ») est lancé.

## Installation

1. Téléchargez **[`PC-Doctor.exe`](https://github.com/doninj/pc-doctor/releases/latest/download/PC-Doctor.exe)** (dernière version).
2. Double-cliquez dessus. Pas d'installation nécessaire.
3. Pour tout analyser et tout pouvoir modifier, cliquez sur **« Passer en administrateur »** en bas à gauche.

> L'exécutable n'est pas signé : Windows SmartScreen peut afficher un avertissement. Cliquez sur « Informations complémentaires » puis « Exécuter quand même ». Le code source complet est dans ce dépôt si vous voulez vérifier ce qu'il fait.

**Configuration requise :** Windows 10 ou 11 (PowerShell 5.1 et .NET Framework 4, déjà inclus dans Windows).

## Lancer depuis le code source

```bat
git clone <url de ce dépôt>
cd pc-doctor
"Lancer PC Doctor.bat"
```

Ou directement : `powershell -ExecutionPolicy Bypass -STA -File PCDoctor.ps1`

Mode test sans interface (affiche le diagnostic dans la console) :

```bat
powershell -ExecutionPolicy Bypass -STA -File PCDoctor.ps1 -SelfTest
```

## Recompiler l'exécutable

```bat
powershell -ExecutionPolicy Bypass -File build\build.ps1
```

Le script régénère le logo, puis compile `PC Doctor.exe` avec le compilateur C# fourni avec Windows (aucun outil à installer). L'exécutable est un petit lanceur qui contient `PCDoctor.ps1` et le logo, les extrait dans `%LOCALAPPDATA%\PCDoctor\app` et ouvre l'interface sans fenêtre console.

## Structure

```
PCDoctor.ps1           Application (interface WPF + diagnostic + moteur de scan en C# intégré)
Lancer PC Doctor.bat   Lanceur depuis le code source
build/
  build.ps1            Compilation de l'exécutable
  Launcher.cs          Code du lanceur .exe
  make-icon.ps1        Génération du logo
  PCDoctor.ico / .png  Logo
```

## Licence

[MIT](LICENSE)
