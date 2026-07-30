defmodule Atomboy.Native.RV32 do
  @moduledoc """
  L'encodeur RISC-V 32 bits — une instruction, quatre octets.

  Le même pari que `Atomboy.CPU.Table` : décrire l'encodage en donnée et laisser
  la génération produire les fonctions. Les cinq formats de RV32I tiennent en
  quelques lignes chacun, et une instruction ne coûte alors qu'une entrée de
  table — `{:add, "add", 0x00, 0x0}` — plutôt qu'un corps recopié.

  ## Les formats

      R  funct7[31:25] rs2[24:20] rs1[19:15] funct3[14:12] rd[11:7] opcode[6:0]
      I  imm[31:20]              rs1        funct3        rd       opcode
      S  imm[11:5]     rs2       rs1        funct3        imm[4:0] opcode
      B  imm[12|10:5]  rs2       rs1        funct3        imm[4:1|11] opcode
      U  imm[31:12]                                       rd       opcode
      J  imm[20|10:1|11|19:12]                            rd       opcode

  Les formats B et J réordonnent les bits de l'immédiat au lieu de les poser
  d'affilée. Ce n'est pas une coquetterie : le découpage aligne chaque bit sur la
  position qu'il occupe déjà dans les autres formats, ce qui économise du câblage
  dans le décodeur matériel. Pour nous c'est juste un piège à recopier
  soigneusement, d'où l'oracle externe : `riscv64-unknown-elf-as` assemble le
  même texte, `objdump` le redonne en octets, et le test compare.

  ## Rien de compressé

  RV32C sait coder certaines instructions sur deux octets. On n'en émet aucune,
  délibérément. La taille d'une instruction compressée dépend de ses opérandes —
  et pour un branchement, de la distance à sa cible, laquelle dépend de la taille
  des instructions intermédiaires. C'est un point fixe, et le résoudre demande un
  assembleur bien plus gros que celui d'`Atomboy.Native.Asm`. Tout fait quatre
  octets : la passe 1 connaît chaque adresse avant d'émettre un seul octet.

  Le jour où la taille du code deviendra le facteur limitant — c'est le sujet du
  projet, donc ce jour viendra — la compression s'ajoutera là où elle est sûre :
  les instructions dont les opérandes sont connus à l'émission, jamais celles qui
  visent une étiquette.
  """

  import Bitwise

  @regs %{
    zero: 0,
    ra: 1,
    sp: 2,
    gp: 3,
    tp: 4,
    t0: 5,
    t1: 6,
    t2: 7,
    s0: 8,
    s1: 9,
    a0: 10,
    a1: 11,
    a2: 12,
    a3: 13,
    a4: 14,
    a5: 15,
    a6: 16,
    a7: 17,
    s2: 18,
    s3: 19,
    s4: 20,
    s5: 21,
    s6: 22,
    s7: 23,
    s8: 24,
    s9: 25,
    s10: 26,
    s11: 27,
    t3: 28,
    t4: 29,
    t5: 30,
    t6: 31
  }

  @typedoc "Un registre, désigné par son nom ABI."
  @type reg ::
          :zero
          | :ra
          | :sp
          | :gp
          | :tp
          | :t0
          | :t1
          | :t2
          | :t3
          | :t4
          | :t5
          | :t6
          | :s0
          | :s1
          | :s2
          | :s3
          | :s4
          | :s5
          | :s6
          | :s7
          | :s8
          | :s9
          | :s10
          | :s11
          | :a0
          | :a1
          | :a2
          | :a3
          | :a4
          | :a5
          | :a6
          | :a7

  @doc "Le numéro d'un registre. Lève sur un nom inconnu — une faute de frappe ne doit pas encoder."
  @spec reg(reg()) :: 0..31
  def reg(name) do
    case @regs do
      %{^name => number} ->
        number

      _ ->
        raise ArgumentError,
              "registre RV32 inconnu : #{inspect(name)} — les noms sont ceux de l'ABI (#{@regs |> Map.keys() |> Enum.sort() |> Enum.join(", ")})"
    end
  end

  @doc "Tous les noms de registres, du plus petit numéro au plus grand."
  @spec regs() :: [reg()]
  def regs, do: @regs |> Enum.sort_by(&elem(&1, 1)) |> Enum.map(&elem(&1, 0))

  # ══ Les tables ═══════════════════════════════════════════════════════════════
  #
  # Chaque entrée : {nom Elixir, mnémonique assembleur, …champs d'encodage}. Le
  # nom diffère du mnémonique pour `and`, `or` et `xor`, qui sont des formes
  # spéciales d'Elixir et ne peuvent pas être des noms de fonction.

  @r_type [
    {:add, "add", 0x00, 0x0},
    {:sub, "sub", 0x20, 0x0},
    {:sll, "sll", 0x00, 0x1},
    {:slt, "slt", 0x00, 0x2},
    {:sltu, "sltu", 0x00, 0x3},
    {:xor_, "xor", 0x00, 0x4},
    {:srl, "srl", 0x00, 0x5},
    {:sra, "sra", 0x20, 0x5},
    {:or_, "or", 0x00, 0x6},
    {:and_, "and", 0x00, 0x7}
  ]

  @i_type [
    {:addi, "addi", 0x13, 0x0},
    {:slti, "slti", 0x13, 0x2},
    {:sltiu, "sltiu", 0x13, 0x3},
    {:xori, "xori", 0x13, 0x4},
    {:ori, "ori", 0x13, 0x6},
    {:andi, "andi", 0x13, 0x7},
    {:jalr, "jalr", 0x67, 0x0}
  ]

  @load_type [
    {:lb, "lb", 0x0},
    {:lh, "lh", 0x1},
    {:lw, "lw", 0x2},
    {:lbu, "lbu", 0x4},
    {:lhu, "lhu", 0x5}
  ]

  @shift_type [
    {:slli, "slli", 0x00, 0x1},
    {:srli, "srli", 0x00, 0x5},
    {:srai, "srai", 0x20, 0x5}
  ]

  @s_type [
    {:sb, "sb", 0x0},
    {:sh, "sh", 0x1},
    {:sw, "sw", 0x2}
  ]

  @b_type [
    {:beq, "beq", 0x0},
    {:bne, "bne", 0x1},
    {:blt, "blt", 0x4},
    {:bge, "bge", 0x5},
    {:bltu, "bltu", 0x6},
    {:bgeu, "bgeu", 0x7}
  ]

  @u_type [
    {:lui, "lui", 0x37},
    {:auipc, "auipc", 0x17}
  ]

  # ══ Les émetteurs, générés ═══════════════════════════════════════════════════

  for {name, asm, funct7, funct3} <- @r_type do
    @doc "`#{asm} rd, rs1, rs2`"
    @spec unquote(name)(reg(), reg(), reg()) :: binary()
    def unquote(name)(rd, rs1, rs2) do
      encode(
        <<unquote(funct7)::7, reg(rs2)::5, reg(rs1)::5, unquote(funct3)::3, reg(rd)::5, 0x33::7>>
      )
    end
  end

  for {name, asm, opcode, funct3} <- @i_type do
    @doc "`#{asm} rd, rs1, imm` — l'immédiat est signé sur 12 bits."
    @spec unquote(name)(reg(), reg(), -2048..2047) :: binary()
    def unquote(name)(rd, rs1, imm) do
      check_imm!(unquote(asm), imm, -2048, 2047)
      encode(<<imm::12, reg(rs1)::5, unquote(funct3)::3, reg(rd)::5, unquote(opcode)::7>>)
    end
  end

  for {name, asm, funct3} <- @load_type do
    @doc "`#{asm} rd, imm(rs1)`"
    @spec unquote(name)(reg(), reg(), -2048..2047) :: binary()
    def unquote(name)(rd, rs1, imm) do
      check_imm!(unquote(asm), imm, -2048, 2047)
      encode(<<imm::12, reg(rs1)::5, unquote(funct3)::3, reg(rd)::5, 0x03::7>>)
    end
  end

  for {name, asm, funct7, funct3} <- @shift_type do
    @doc "`#{asm} rd, rs1, shamt` — le décalage tient sur 5 bits."
    @spec unquote(name)(reg(), reg(), 0..31) :: binary()
    def unquote(name)(rd, rs1, shamt) do
      check_imm!(unquote(asm), shamt, 0, 31)

      encode(
        <<unquote(funct7)::7, shamt::5, reg(rs1)::5, unquote(funct3)::3, reg(rd)::5, 0x13::7>>
      )
    end
  end

  for {name, asm, funct3} <- @s_type do
    @doc "`#{asm} rs2, imm(rs1)`"
    @spec unquote(name)(reg(), reg(), -2048..2047) :: binary()
    def unquote(name)(rs2, rs1, imm) do
      check_imm!(unquote(asm), imm, -2048, 2047)
      <<high::7, low::5>> = <<imm::12>>
      encode(<<high::7, reg(rs2)::5, reg(rs1)::5, unquote(funct3)::3, low::5, 0x23::7>>)
    end
  end

  for {name, asm, funct3} <- @b_type do
    @doc """
    `#{asm} rs1, rs2, offset` — l'offset est relatif à l'instruction elle-même,
    pair, et tient sur 13 bits signés (±4 Ko).
    """
    @spec unquote(name)(reg(), reg(), integer()) :: binary()
    def unquote(name)(rs1, rs2, offset) do
      check_branch!(unquote(asm), offset, -4096, 4094)
      <<b12::1, b11::1, b10_5::6, b4_1::4, 0::1>> = <<offset::13>>

      encode(
        <<b12::1, b10_5::6, reg(rs2)::5, reg(rs1)::5, unquote(funct3)::3, b4_1::4, b11::1,
          0x63::7>>
      )
    end
  end

  for {name, asm, opcode} <- @u_type do
    @doc "`#{asm} rd, imm` — les 20 bits de poids fort, l'immédiat étant déjà décalé."
    @spec unquote(name)(reg(), 0..0xFFFFF) :: binary()
    def unquote(name)(rd, imm) do
      check_imm!(unquote(asm), imm, 0, 0xFFFFF)
      encode(<<imm::20, reg(rd)::5, unquote(opcode)::7>>)
    end
  end

  @doc """
  `jal rd, offset` — saut relatif, pair, sur 21 bits signés (±1 Mo).

  La portée décide de la forme des tables de saut : à ±1 Mo, un `j` couvre
  n'importe quelle cible de l'interpréteur sans détour.
  """
  @spec jal(reg(), integer()) :: binary()
  def jal(rd, offset) do
    check_branch!("jal", offset, -1_048_576, 1_048_574)
    <<b20::1, b19_12::8, b11::1, b10_1::10, 0::1>> = <<offset::21>>
    encode(<<b20::1, b10_1::10, b11::1, b19_12::8, reg(rd)::5, 0x6F::7>>)
  end

  @doc """
  `csrrs rd, csr, rs1` — lit un registre de contrôle.

  Une seule adresse nous intéresse : `0xC02`, le compteur `instret`
  d'instructions retirées. Sous `qemu -icount shift=0` il compte exactement les
  instructions exécutées, ce qui donne la mesure du projet — instructions RV32
  par instruction SM83 — sans greffon ni ligne de C.
  """
  @spec csrrs(reg(), 0..0xFFF, reg()) :: binary()
  def csrrs(rd, csr, rs1) do
    check_imm!("csrrs", csr, 0, 0xFFF)
    encode(<<csr::12, reg(rs1)::5, 0x2::3, reg(rd)::5, 0x73::7>>)
  end

  # ══ Pseudo-instructions ══════════════════════════════════════════════════════

  @doc """
  `li rd, valeur` — charge une constante quelconque, en une ou deux instructions.

  Le piège : `addi` sign-étend son immédiat. Quand les 12 bits de poids faible
  dépassent 0x7FF, ils s'interprètent en négatif et retranchent 0x1000 au
  résultat — il faut donc ajouter 1 aux bits hauts pour compenser. L'arrondi
  `(valeur + 0x800) >>> 12` fait exactement cela.

  Second piège, trouvé par l'oracle : la valeur est d'abord ramenée à un entier
  signé sur 32 bits. Sans cela `0xFFFFFFFF` — la même valeur que `-1`, écrite
  autrement — sortait en deux instructions au lieu d'une.
  """
  @spec li(reg(), integer()) :: [binary()]
  def li(rd, value) do
    word = value &&& 0xFFFFFFFF
    signed = if word > 0x7FFFFFFF, do: word - 0x100000000, else: word

    if signed >= -2048 and signed <= 2047 do
      [addi(rd, :zero, signed)]
    else
      high = (word + 0x800) >>> 12 &&& 0xFFFFF
      low = word - (high <<< 12) &&& 0xFFF
      low = if low > 0x7FF, do: low - 0x1000, else: low

      case low do
        0 -> [lui(rd, high)]
        _ -> [lui(rd, high), addi(rd, rd, low)]
      end
    end
  end

  @doc "`nop` — le `addi zero, zero, 0` canonique."
  @spec nop() :: binary()
  def nop, do: addi(:zero, :zero, 0)

  @doc "`mv rd, rs` — une copie de registre."
  @spec mv(reg(), reg()) :: binary()
  def mv(rd, rs), do: addi(rd, rs, 0)

  @doc "`j offset` — un saut qui ne garde pas d'adresse de retour."
  @spec j(integer()) :: binary()
  def j(offset), do: jal(:zero, offset)

  @doc "`jr rs` — un saut vers l'adresse contenue dans un registre."
  @spec jr(reg()) :: binary()
  def jr(rs), do: jalr(:zero, rs, 0)

  @doc "`ret` — le retour d'une sous-routine, `jr ra`."
  @spec ret() :: binary()
  def ret, do: jr(:ra)

  # ══ Introspection ════════════════════════════════════════════════════════════

  @doc """
  Toutes les formes émises, en donnée — le test différentiel les parcourt.

  Chaque entrée décrit comment appeler l'émetteur et comment écrire la même
  instruction pour `riscv64-unknown-elf-as`, ce qui permet au test de couvrir
  automatiquement toute nouvelle instruction ajoutée aux tables.
  """
  @spec forms() :: [%{name: atom(), asm: String.t(), shape: atom()}]
  def forms do
    Enum.map(@r_type, fn {name, asm, _, _} -> %{name: name, asm: asm, shape: :rrr} end) ++
      Enum.map(@i_type, fn {name, asm, _, _} -> %{name: name, asm: asm, shape: shape_i(name)} end) ++
      Enum.map(@load_type, fn {name, asm, _} -> %{name: name, asm: asm, shape: :load} end) ++
      Enum.map(@shift_type, fn {name, asm, _, _} -> %{name: name, asm: asm, shape: :shift} end) ++
      Enum.map(@s_type, fn {name, asm, _} -> %{name: name, asm: asm, shape: :store} end) ++
      Enum.map(@b_type, fn {name, asm, _} -> %{name: name, asm: asm, shape: :branch} end) ++
      Enum.map(@u_type, fn {name, asm, _} -> %{name: name, asm: asm, shape: :upper} end)
  end

  # jalr s'écrit comme un chargement chez as : `jalr rd, imm(rs1)`.
  defp shape_i(:jalr), do: :load
  defp shape_i(_), do: :rri

  # ══ Le socle ═════════════════════════════════════════════════════════════════

  # Les champs sont posés du bit 31 au bit 0, puis relus en petit-boutien : c'est
  # dans cet ordre que la documentation RISC-V les présente, et c'est le seul
  # moyen que la relecture d'un encodage soit possible.
  defp encode(<<word::32>>), do: <<word::32-little>>

  defp check_imm!(mnemonic, value, low, high) when is_integer(value) do
    unless value >= low and value <= high do
      raise ArgumentError,
            "#{mnemonic} : l'immédiat #{value} sort de la portée #{low}..#{high}"
    end
  end

  defp check_imm!(mnemonic, value, _low, _high) do
    raise ArgumentError, "#{mnemonic} : l'immédiat #{inspect(value)} n'est pas un entier"
  end

  defp check_branch!(mnemonic, offset, low, high) do
    check_imm!(mnemonic, offset, low, high)

    unless rem(offset, 2) == 0 do
      raise ArgumentError,
            "#{mnemonic} : le déplacement #{offset} est impair — les instructions sont alignées"
    end
  end
end
