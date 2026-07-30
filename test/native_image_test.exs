defmodule Atomboy.NativeImageTest do
  @moduledoc """
  L'image de fumée, de bout en bout.

  Ce test ne vérifie pas grand-chose sur le papier — trois lettres sur un port
  série. Ce qu'il verrouille, ce sont les quatre suppositions dont dépend tout
  le harnais, et qu'aucune lecture de documentation ne tranche avec certitude :
  le processeur démarre bien à `0x8000_0000` sur un binaire brut, l'UART veut
  qu'on interroge son registre d'état, `sifive_test` rend la main proprement, et
  l'Elixir n'a besoin ni de compilateur C ni d'éditeur de liens pour produire
  tout cela.
  """

  use ExUnit.Case, async: true

  alias Atomboy.Native.Image
  alias Atomboy.Native.Qemu

  @moduletag :qemu

  test "l'image de fumée boote, parle, et s'éteint" do
    image = Image.smoke()

    resultat = Qemu.run(image.code, timeout: 15_000)

    assert resultat.status == :ok, "qemu n'a pas rendu la main — l'invité boucle"
    assert resultat.exit_status == 0
    assert resultat.serial == "OK\n"
  end

  test "l'image reste minuscule — c'est la promesse du chantier" do
    image = Image.smoke()

    assert image.size < 512,
           "le socle a grossi à #{image.size} octets ; l'icache du C6 fait 32 Ko"

    assert rem(image.size, 4) == 0
  end

  test "le point d'entrée est bien le premier octet" do
    image = Image.smoke()
    assert image.labels[:_start] == 0
  end

  test "un délai de garde interrompt un invité qui boucle" do
    # Une image qui ne s'éteint jamais : le premier octet saute sur lui-même.
    bouclette = Image.build([{:label, :bloque}, Atomboy.Native.Asm.j(:bloque)])

    resultat = Qemu.run(bouclette.code, timeout: 1_500)

    assert resultat.status == :timeout
    assert resultat.duration_us >= 1_500_000
  end
end
