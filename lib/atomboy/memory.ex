defmodule Atomboy.Memory do
  @moduledoc """
  La frontière mémoire — la décision structurante du projet.

  Ce comportement est volontairement minimal et **stable dans le temps** : c'est
  la même API qui sera implémentée par des backends très différents au fil des
  phases.

    * Phase 1 (Mac, tests SM83) — `Atomboy.Memory.Flat`, une map creuse. Suffit
      pour les vecteurs SingleStepTests, qui ne touchent qu'une poignée
      d'adresses.
    * Phase 1bis (ROMs blargg) — un backend segmenté : la ROM est une binary
      BEAM (immuable, donc lue par pattern matching sans copie), seules les
      régions réellement mutables sont dans une structure à part.
    * Phase 3 (ESP32) — VRAM/OAM deviennent une resource C, `read8/2` et
      `write8/3` deviennent des NIF. Le PPU y accède directement en C.

  ## Pourquoi `write8/3` renvoie la mémoire

  Un backend pur (map, binary) doit renvoyer une nouvelle valeur ; un backend
  NIF renvoie la même référence de resource. Le CPU thread la valeur de retour
  dans les deux cas, donc le même code marche sur les deux backends. Le coût sur
  le backend NIF est nul (on renvoie le terme reçu).

  ## Pourquoi `read16/2` et `write16/3` sont dans le comportement

  Ce ne sont pas des sucres syntaxiques : ce sont les **accesseurs en bloc**
  identifiés dans le brief. Sur le backend NIF, chaque accès mémoire du CPU est
  un appel de NIF, et le fetch d'opcode est lui-même un accès. Un `push`/`pop`
  qui fait deux accès en un seul appel divise par deux le trafic sur la
  frontière — ça se voit sur le profil. Les implémenter comme deux `read8`
  serait passer à côté du but ; un backend sérieux les implémente nativement.
  """

  @typedoc "Le terme opaque qui porte l'état mémoire. Sa forme dépend du backend."
  @type t :: term()

  @type addr :: 0..0xFFFF
  @type value :: 0..0xFF

  @callback read8(t, addr) :: value
  @callback write8(t, addr, value) :: t

  @doc """
  Lecture 16 bits little-endian. `addr + 1` boucle à 0x0000.
  """
  @callback read16(t, addr) :: 0..0xFFFF

  @doc """
  Écriture 16 bits little-endian. `addr + 1` boucle à 0x0000.
  """
  @callback write16(t, addr, 0..0xFFFF) :: t
end
