defmodule Atomboy.Native.Image do
  @moduledoc """
  L'image bootable — du binaire brut, sans compilateur C ni éditeur de liens.

  La carte `virt` de qemu démarre le processeur à `0x8000_0000`, exactement là où
  `-kernel` dépose un fichier binaire. Il n'y a donc rien à lier : le premier
  octet émis par `Atomboy.Native.Asm` est la première instruction exécutée.

  C'est ce qui rend le harnais tenable. Aucune chaîne de compilation croisée à
  installer, aucun script d'édition de liens à maintenir, aucun format objet à
  produire — l'Elixir émet des octets, qemu les exécute.

  ## La carte mémoire de `virt`

      0x0010_0000  sifive_test  — y écrire 0x5555 éteint la machine
      0x1000_0000  UART 16550   — +0 la donnée, +5 l'état
      0x8000_0000  la RAM, et notre image

  L'UART veut qu'on attende le bit 5 de son registre d'état (« le registre
  d'émission est libre ») avant chaque octet. qemu accepterait qu'on écrive sans
  attendre, mais du vrai matériel non, et cette routine finira sur du vrai
  matériel.

  ## Ce que le socle fournit

  `putc` écrit un octet, `puts` une chaîne, `poweroff` termine la machine. Ce
  sont les seules primitives d'entrée-sortie du projet : tout ce qui remonte de
  l'invité — résultats de vecteurs, registres, empreintes mémoire — passe par
  cet octet-là.
  """

  alias Atomboy.Native.Asm
  alias Atomboy.Native.RV32

  @base 0x8000_0000
  @uart 0x1000_0000
  @test_device 0x0010_0000
  @stack_top 0x8010_0000

  @doc "L'adresse de chargement de l'image."
  @spec base() :: non_neg_integer()
  def base, do: @base

  @doc """
  Construit une image complète : le préambule, le corps, puis le socle.

  Le corps reçoit la main avec la pile installée ; il termine en sautant à
  `:poweroff`, ou en tombant dedans.
  """
  @spec build([Asm.item()]) :: Atomboy.Native.Asm.assembled()
  def build(body) do
    Asm.assemble([prelude(), body, runtime()], @base)
  end

  @doc """
  L'image de fumée : elle dit bonjour et s'éteint.

  Elle n'émule rien. Son rôle est de fermer, une fois pour toutes, les questions
  auxquelles aucune lecture de documentation ne répond avec certitude — le
  processeur démarre-t-il bien à `0x8000_0000`, l'UART veut-il qu'on interroge
  son état, `sifive_test` rend-il la main proprement.
  """
  @spec smoke() :: Atomboy.Native.Asm.assembled()
  def smoke do
    build([
      RV32.li(:a0, ?O),
      Asm.call(:putc),
      RV32.li(:a0, ?K),
      Asm.call(:putc),
      RV32.li(:a0, ?\n),
      Asm.call(:putc),
      Asm.j(:poweroff)
    ])
  end

  # ══ Le préambule ═════════════════════════════════════════════════════════════

  defp prelude do
    [
      Asm.label(:_start),
      RV32.li(:sp, @stack_top)
    ]
  end

  # ══ Le socle ═════════════════════════════════════════════════════════════════

  defp runtime do
    [putc(), puts(), poweroff()]
  end

  # a0 : l'octet à émettre. Écrase t0 et t1, préserve tout le reste.
  defp putc do
    [
      Asm.label(:putc),
      RV32.li(:t0, @uart),
      Asm.label(:putc_attente),
      RV32.lbu(:t1, :t0, 5),
      RV32.andi(:t1, :t1, 0x20),
      Asm.beqz(:t1, :putc_attente),
      RV32.sb(:a0, :t0, 0),
      RV32.ret()
    ]
  end

  # a1 : l'adresse d'une chaîne, a2 : sa longueur. Écrase a0, t0, t1, t2.
  defp puts do
    [
      Asm.label(:puts),
      RV32.mv(:t2, :ra),
      Asm.label(:puts_boucle),
      Asm.beqz(:a2, :puts_fin),
      RV32.lbu(:a0, :a1, 0),
      Asm.call(:putc),
      RV32.addi(:a1, :a1, 1),
      RV32.addi(:a2, :a2, -1),
      Asm.j(:puts_boucle),
      Asm.label(:puts_fin),
      RV32.jr(:t2)
    ]
  end

  # La boucle finale n'est pas de la superstition : l'écriture sur sifive_test
  # n'arrête pas le processeur, elle demande à qemu de rendre la main. Les
  # quelques instructions suivantes s'exécutent quand même, et sans la boucle
  # elles seraient ce qui suit dans l'image.
  defp poweroff do
    [
      Asm.label(:poweroff),
      RV32.li(:t0, @test_device),
      RV32.li(:t1, 0x5555),
      RV32.sw(:t1, :t0, 0),
      Asm.label(:poweroff_boucle),
      Asm.j(:poweroff_boucle)
    ]
  end
end
