defmodule Atomboy.RV32Test do
  @moduledoc """
  L'encodeur contre un oracle externe : `riscv64-unknown-elf-as`.

  Comparer du texte désassemblé ne prouverait rien de plus que notre propre
  compréhension de la syntaxe. On compare donc des octets : le même programme
  est écrit en assembleur, passé à binutils, réduit en binaire brut, et confronté
  octet pour octet à ce que l'encodeur produit.

  Tout le corpus tient dans un seul fichier assemblé une fois — quelques
  centaines de cas pour le prix d'un lancement de processus.

  Les cas sont dérivés de `RV32.forms/0` : une instruction ajoutée aux tables de
  l'encodeur est automatiquement couverte ici, sans rien écrire.
  """

  use ExUnit.Case, async: true

  alias Atomboy.Native.RV32

  @as "riscv64-unknown-elf-as"
  @objcopy "riscv64-unknown-elf-objcopy"

  # Un échantillon qui couvre les frontières d'encodage : x0, les numéros à un
  # chiffre, la plage compressible x8-x15, et le haut du banc.
  @sample_regs [:zero, :ra, :t0, :s0, :a0, :a5, :s11, :t6]
  @imm12 [0, 1, -1, 5, -5, 2047, -2048]
  @shamt [0, 1, 5, 31]
  @offsets [0, 2, -2, 8, -8, 4094, -4096]
  @upper [0, 1, 0x12345, 0xFFFFF]

  describe "l'encodage, contre binutils" do
    @describetag :binutils

    test "chaque forme émise s'encode comme le fait as" do
      cases = build_cases()
      assert length(cases) > 200, "le corpus doit couvrir toutes les formes"

      expected = assemble(Enum.map(cases, & &1.text))

      assert byte_size(expected) == length(cases) * 4,
             "as a produit #{byte_size(expected)} octets pour #{length(cases)} instructions — " <>
               "une forme a probablement été compressée ou relaxée"

      mismatches =
        cases
        |> Enum.zip(for <<word::binary-4 <- expected>>, do: word)
        |> Enum.reject(fn {c, word} -> c.bytes == word end)
        |> Enum.map(fn {c, word} ->
          "  #{c.text}\n    encodeur : #{hex(c.bytes)}\n    as       : #{hex(word)}"
        end)

      assert mismatches == [],
             "#{length(mismatches)} encodages divergent :\n" <> Enum.join(mismatches, "\n")
    end
  end

  describe "les portées" do
    test "un immédiat hors plage lève, en nommant l'instruction" do
      assert_raise ArgumentError, ~r/addi.*2048.*-2048\.\.2047/, fn ->
        RV32.addi(:a0, :a0, 2048)
      end

      assert_raise ArgumentError, ~r/andi/, fn -> RV32.andi(:a0, :a0, -2049) end
      assert_raise ArgumentError, ~r/slli/, fn -> RV32.slli(:a0, :a0, 32) end
      assert_raise ArgumentError, ~r/lui/, fn -> RV32.lui(:a0, 0x100000) end
    end

    test "un branchement impair ou trop lointain lève" do
      assert_raise ArgumentError, ~r/impair/, fn -> RV32.beq(:a0, :a1, 3) end
      assert_raise ArgumentError, ~r/beq/, fn -> RV32.beq(:a0, :a1, 4096) end
      assert_raise ArgumentError, ~r/jal/, fn -> RV32.jal(:ra, 1_048_576) end
    end

    test "un registre inconnu lève plutôt que d'encoder n'importe quoi" do
      assert_raise ArgumentError, ~r/registre RV32 inconnu/, fn -> RV32.add(:x9, :a0, :a0) end
    end
  end

  describe "li, la pseudo-instruction" do
    test "une petite constante tient en une instruction" do
      assert RV32.li(:a0, 42) == [RV32.addi(:a0, :zero, 42)]
      assert RV32.li(:a0, -2048) == [RV32.addi(:a0, :zero, -2048)]
    end

    test "une grande constante compense la sign-extension du addi" do
      # 0x800 : les 12 bits bas valent -2048 une fois étendus, donc les bits
      # hauts doivent être incrémentés pour compenser.
      assert [lui, addi] = RV32.li(:a0, 0x800)
      assert lui == RV32.lui(:a0, 0x1)
      assert addi == RV32.addi(:a0, :a0, -2048)
    end

    test "une constante dont les bits bas sont nuls se passe du addi" do
      assert RV32.li(:a0, 0x8000_0000) == [RV32.lui(:a0, 0x80000)]
    end

    @tag :binutils
    test "les constantes remarquables s'encodent comme chez as" do
      values = [
        0,
        1,
        -1,
        2047,
        2048,
        -2048,
        -2049,
        0x800,
        0xFFF,
        0x1000,
        0x10000000,
        0x80000000,
        0xFFFFFFFF
      ]

      texts = Enum.map(values, fn v -> "li a0, #{signed(v)}" end)
      expected = assemble(texts, ".option nopic")

      ours = values |> Enum.map(&RV32.li(:a0, &1)) |> IO.iodata_to_binary()

      assert ours == expected
    end
  end

  # ══ Le corpus ════════════════════════════════════════════════════════════════

  defp build_cases do
    Enum.flat_map(RV32.forms(), &cases_for/1) ++ extra_cases()
  end

  defp cases_for(%{name: name, asm: asm, shape: :rrr}) do
    for {rd, rs1, rs2} <- triples() do
      one(name, [rd, rs1, rs2], "#{asm} #{rd}, #{rs1}, #{rs2}")
    end
  end

  defp cases_for(%{name: name, asm: asm, shape: :rri}) do
    for {rd, rs1} <- pairs(), imm <- @imm12 do
      one(name, [rd, rs1, imm], "#{asm} #{rd}, #{rs1}, #{imm}")
    end
  end

  defp cases_for(%{name: name, asm: asm, shape: :load}) do
    for {rd, rs1} <- pairs(), imm <- @imm12 do
      one(name, [rd, rs1, imm], "#{asm} #{rd}, #{imm}(#{rs1})")
    end
  end

  defp cases_for(%{name: name, asm: asm, shape: :shift}) do
    for {rd, rs1} <- pairs(), shamt <- @shamt do
      one(name, [rd, rs1, shamt], "#{asm} #{rd}, #{rs1}, #{shamt}")
    end
  end

  defp cases_for(%{name: name, asm: asm, shape: :store}) do
    for {rs2, rs1} <- pairs(), imm <- @imm12 do
      one(name, [rs2, rs1, imm], "#{asm} #{rs2}, #{imm}(#{rs1})")
    end
  end

  defp cases_for(%{name: name, asm: asm, shape: :branch}) do
    for {rs1, rs2} <- pairs(), offset <- @offsets do
      one(name, [rs1, rs2, offset], "#{asm} #{rs1}, #{rs2}, .#{signed_offset(offset)}")
    end
  end

  defp cases_for(%{name: name, asm: asm, shape: :upper}) do
    for rd <- @sample_regs, imm <- @upper do
      one(name, [rd, imm], "#{asm} #{rd}, #{imm}")
    end
  end

  defp extra_cases do
    jal =
      for rd <- @sample_regs, offset <- [0, 4, -4, 1_048_574, -1_048_576] do
        one(:jal, [rd, offset], "jal #{rd}, .#{signed_offset(offset)}")
      end

    csr = [one(:csrrs, [:t0, 0xC02, :zero], "csrrs t0, 0xc02, zero")]

    pseudo = [
      %{text: "nop", bytes: RV32.nop()},
      %{text: "mv a0, a1", bytes: RV32.mv(:a0, :a1)},
      %{text: "jr a0", bytes: RV32.jr(:a0)},
      %{text: "ret", bytes: RV32.ret()}
    ]

    jal ++ csr ++ pseudo
  end

  defp one(name, args, text), do: %{text: text, bytes: apply(RV32, name, args)}

  # Deux et trois registres pris en parallèle plutôt qu'en produit cartésien :
  # le produit ferait 512 cas par forme sans rien couvrir de plus, chaque champ
  # de registre étant encodé indépendamment des autres.
  defp pairs do
    Enum.zip(@sample_regs, Enum.reverse(@sample_regs))
  end

  defp triples do
    rotated = tl(@sample_regs) ++ [hd(@sample_regs)]
    Enum.zip([@sample_regs, Enum.reverse(@sample_regs), rotated])
  end

  # ══ L'oracle ═════════════════════════════════════════════════════════════════

  defp assemble(texts, directives \\ "") do
    dir = Path.join(System.tmp_dir!(), "atomboy-rv32-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    source = Path.join(dir, "corpus.s")
    object = Path.join(dir, "corpus.o")
    binary = Path.join(dir, "corpus.bin")

    File.write!(source, [".option norvc\n", directives, "\n.text\n", Enum.map(texts, &[&1, "\n"])])

    {output, code} =
      System.cmd(@as, ["-march=rv32imac_zicsr", "-mabi=ilp32", source, "-o", object],
        stderr_to_stdout: true
      )

    assert code == 0, "as a refusé le corpus :\n#{output}"

    {output, code} =
      System.cmd(@objcopy, ["-O", "binary", object, binary], stderr_to_stdout: true)

    assert code == 0, "objcopy a échoué :\n#{output}"

    bytes = File.read!(binary)
    File.rm_rf(dir)
    bytes
  end

  defp hex(<<a, b, c, d>>), do: Enum.map_join([d, c, b, a], "", &Base.encode16(<<&1>>))

  defp signed(v) when v > 0x7FFFFFFF, do: Integer.to_string(v - 0x100000000)
  defp signed(v), do: Integer.to_string(v)

  defp signed_offset(offset) when offset >= 0, do: "+#{offset}"
  defp signed_offset(offset), do: Integer.to_string(offset)
end
