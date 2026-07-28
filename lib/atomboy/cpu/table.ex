defmodule Atomboy.CPU.Table do
  @moduledoc """
  La table d'instructions du SM83, en donnée.

  C'est le seul fichier à éditer pour ajouter une famille d'opcodes. Il ne
  contient aucun code exécutable, aucune manipulation d'AST, aucune convention
  d'appel : uniquement la description de ce que fait le processeur.
  `Atomboy.CPU.Gen` traduit, `Atomboy.CPU` accueille les clauses.

  ## La décomposition octale

  La table SM83 est régulière quand on lit l'octet d'opcode en trois champs :
  `x` (bits 7-6), `y` (bits 5-3), `z` (bits 2-0).

      x=0  → opérations diverses, régulières en (y, z)
      x=1  → LD r, r'  sur 0x40-0x7F, sauf 0x76 réquisitionné par HALT
      x=2  → ALU A, r  — 8 opérations × 8 sources
      x=3  → sauts, pile, appels

  D'où des familles générées en compréhension plutôt que 500 lignes recopiées à
  la main. Une correction de drapeau se fait alors à un seul endroit, et les
  fautes de frappe silencieuses — celles que les vecteurs de test ne distinguent
  pas toujours d'un vrai bug — n'ont plus où se loger.
  """

  alias Atomboy.CPU.Insn

  # L'encodage `r` sur 3 bits, commun à toute la table. 6 désigne (HL).
  @r {:b, :c, :d, :e, :h, :l, :hl_ind, :a}

  @doc "L'opérande désigné par un champ `r` de 3 bits."
  @spec operand(0..7) :: Insn.operand()
  def operand(6), do: :hl_ind
  def operand(index), do: {:reg, elem(@r, index)}

  @doc """
  La table de base, sans préfixe.
  """
  @spec base() :: [Insn.t()]
  def base do
    misc() ++
      indirect_block() ++
      jr_block() ++
      acc_block() ++
      stack_block() ++
      jump_block() ++
      alu_imm_block() ++
      pair_block() ++ inc_dec_block() ++ load_imm8_block() ++ load_block() ++ alu_block()
  end

  @doc """
  La table étendue, préfixée par 0xCB. Vide pour l'instant.
  """
  @spec extended() :: [Insn.t()]
  def extended, do: []

  @doc "Toutes les instructions décrites, tous préfixes confondus."
  @spec all() :: [Insn.t()]
  def all, do: base() ++ extended()

  # ── x=0 ─────────────────────────────────────────────────────────────────────

  defp misc do
    [
      %Insn{opcode: 0x00, mnemonic: :nop, cycles: 4},
      # STOP — l'arrêt effectif attend le contrôleur d'horloge. Le matériel
      # l'encode sur deux octets, mais le corpus SingleStepTests le modélise en
      # un seul, à 12 T-cycles : on suit le corpus, qui est l'oracle de cette
      # phase. À revisiter quand STOP fera vraiment quelque chose.
      %Insn{opcode: 0x10, mnemonic: :stop, cycles: 12},
      # LD (a16), SP — la seule écriture 16 bits directe du jeu d'instructions.
      %Insn{opcode: 0x08, mnemonic: :ld, operands: [:a16_ind, {:pair, :sp}], cycles: 20},
      # HALT : 12 T dans le modèle du corpus, comme STOP.
      %Insn{opcode: 0x76, mnemonic: :halt, cycles: 12},
      %Insn{opcode: 0xF3, mnemonic: :di, cycles: 4},
      # EI : l'autorisation est différée d'une instruction — le corpus le
      # vérifie (ime inchangé sur le pas de l'EI). Voir ime_pending.
      %Insn{opcode: 0xFB, mnemonic: :ei, cycles: 4},
      %Insn{opcode: 0xF9, mnemonic: :ld, operands: [{:pair, :sp}, {:pair, :hl}], cycles: 8},
      %Insn{opcode: 0xE8, mnemonic: :add_sp, operands: [{:pair, :sp}, {:imm, 8}], cycles: 16},
      %Insn{opcode: 0xF8, mnemonic: :add_sp, operands: [{:pair, :hl}, {:imm, 8}], cycles: 12},
      # La page haute 0xFF00 — les registres d'E/S. LDH via un octet immédiat,
      # ou via C.
      %Insn{opcode: 0xE0, mnemonic: :ldh, operands: [:a8_ind, {:reg, :a}], cycles: 12},
      %Insn{opcode: 0xF0, mnemonic: :ldh, operands: [{:reg, :a}, :a8_ind], cycles: 12},
      %Insn{opcode: 0xE2, mnemonic: :ldh, operands: [:c_ind, {:reg, :a}], cycles: 8},
      %Insn{opcode: 0xF2, mnemonic: :ldh, operands: [{:reg, :a}, :c_ind], cycles: 8},
      %Insn{opcode: 0xEA, mnemonic: :ld, operands: [:a16_ind, {:reg, :a}], cycles: 16},
      %Insn{opcode: 0xFA, mnemonic: :ld, operands: [{:reg, :a}, :a16_ind], cycles: 16}
    ]
  end

  # ── x=0, z=2 : LD indirects entre A et les paires ───────────────────────────
  #
  # q=0 écrit A en mémoire, q=1 le lit. Les formes HL+ et HL- post-ajustent HL
  # après l'accès — les deux encodages que la paire AF aurait occupés.

  @indirects [{0x02, :bc}, {0x12, :de}, {0x22, :hl_inc}, {0x32, :hl_dec}]

  defp indirect_block do
    stores =
      for {opcode, target} <- @indirects do
        %Insn{opcode: opcode, mnemonic: :ld, operands: [{:ind, target}, {:reg, :a}], cycles: 8}
      end

    loads =
      for {opcode, target} <- @indirects do
        %Insn{
          opcode: opcode + 8,
          mnemonic: :ld,
          operands: [{:reg, :a}, {:ind, target}],
          cycles: 8
        }
      end

    stores ++ loads
  end

  # ── x=0, z=0 : JR ───────────────────────────────────────────────────────────
  #
  # Saut relatif, offset signé d'un octet. Les formes conditionnelles coûtent
  # 12 T-cycles prises, 8 non prises — le premier endroit où la table décrit un
  # comportement dépendant de l'exécution.

  defp jr_block do
    unconditional = %Insn{opcode: 0x18, mnemonic: :jr, operands: [{:imm, 8}], cycles: 12}

    conditionals =
      for {condition, index} <- [nz: 0, z: 1, nc: 2, c: 3] do
        %Insn{
          opcode: 0x20 + index * 8,
          mnemonic: :jr,
          operands: [{:imm, 8}],
          condition: condition,
          cycles: 12,
          cycles_untaken: 8
        }
      end

    [unconditional | conditionals]
  end

  # ── x=0, z=7 : opérations sur l'accumulateur ────────────────────────────────
  #
  # Huit instructions sans opérande explicite — A et F sont implicites. L'ordre
  # du champ `y` est celui du silicium.

  @acc_ops {:rlca, :rrca, :rla, :rra, :daa, :cpl, :scf, :ccf}

  defp acc_block do
    for y <- 0..7 do
      %Insn{opcode: y * 8 + 0x07, mnemonic: elem(@acc_ops, y), cycles: 4}
    end
  end

  # ── x=0 : les paires 16 bits ────────────────────────────────────────────────
  #
  # Le champ `p` (bits 5-4) désigne la paire : BC, DE, HL, SP. Quatre familles
  # sur les colonnes basses : LD rr, d16 (z=1, q=0), ADD HL, rr (z=1, q=1),
  # INC rr (z=3, q=0), DEC rr (z=3, q=1).

  @pairs {:bc, :de, :hl, :sp}

  defp pair(index), do: {:pair, elem(@pairs, index)}

  defp pair_block do
    for p <- 0..3 do
      [
        %Insn{opcode: p * 16 + 0x01, mnemonic: :ld, operands: [pair(p), {:imm, 16}], cycles: 12},
        %Insn{
          opcode: p * 16 + 0x09,
          mnemonic: :add,
          operands: [{:pair, :hl}, pair(p)],
          cycles: 8
        },
        # INC/DEC 16 bits : aucun drapeau touché — contrairement à leurs
        # homonymes 8 bits, et c'est le matériel qui veut ça.
        %Insn{opcode: p * 16 + 0x03, mnemonic: :inc, operands: [pair(p)], cycles: 8},
        %Insn{opcode: p * 16 + 0x0B, mnemonic: :dec, operands: [pair(p)], cycles: 8}
      ]
    end
    |> List.flatten()
  end

  # ── x=0, z=4/z=5 : INC r / DEC r ────────────────────────────────────────────
  #
  # La cible occupe le champ `y`. La forme (HL) est un lu-modifié-écrit :
  # 12 T-cycles (fetch, lecture, écriture) contre 4 pour un registre.

  defp inc_dec_block do
    for {mnemonic, z} <- [inc: 4, dec: 5], target <- 0..7 do
      %Insn{
        opcode: target * 8 + z,
        mnemonic: mnemonic,
        operands: [operand(target)],
        cycles: if(target == 6, do: 12, else: 4)
      }
    end
  end

  # ── x=0, z=6 : LD r, d8 ─────────────────────────────────────────────────────
  #
  # La destination occupe le champ `y`, l'immédiat suit l'opcode. Premier bloc
  # à opérande multi-octet : PC avance de deux au total.

  defp load_imm8_block do
    for dst <- 0..7 do
      %Insn{
        opcode: dst * 8 + 0x06,
        mnemonic: :ld,
        operands: [operand(dst), {:imm, 8}],
        # Fetch de l'opcode, fetch de l'immédiat — plus l'écriture mémoire pour
        # LD (HL), d8.
        cycles: if(dst == 6, do: 12, else: 8)
      }
    end
  end

  # ── x=3 : la pile ───────────────────────────────────────────────────────────
  #
  # Les paires de pile remplacent SP par AF — pousser SP sur lui-même n'aurait
  # aucun sens. PUSH coûte un M-cycle de plus que POP : le matériel décrémente
  # SP avant d'écrire, et cette décrémentation a son propre cycle.

  @stack_pairs {:bc, :de, :hl, :af}

  defp stack_block do
    for p <- 0..3 do
      pair = {:pair, elem(@stack_pairs, p)}

      [
        %Insn{opcode: 0xC1 + p * 16, mnemonic: :pop, operands: [pair], cycles: 12},
        %Insn{opcode: 0xC5 + p * 16, mnemonic: :push, operands: [pair], cycles: 16}
      ]
    end
    |> List.flatten()
  end

  # ── x=3 : sauts absolus, appels, retours ────────────────────────────────────
  #
  # Les quatre conditions partagent l'encodage du champ y avec JR. Les coûts
  # pris/non pris diffèrent par famille : l'écart est le travail réellement
  # évité — lecture de l'opérande déjà faite pour JP (16/12), pile intouchée
  # pour CALL (24/12), lecture de pile évitée pour RET (20/8).

  @conditions [nz: 0, z: 1, nc: 2, c: 3]

  defp jump_block do
    jp =
      [
        %Insn{opcode: 0xC3, mnemonic: :jp, operands: [{:imm, 16}], cycles: 16},
        # JP HL — souvent écrit « JP (HL) », mais il n'y a aucun accès mémoire :
        # PC reçoit la paire, c'est tout. Le saut calculé du futur trampoline.
        %Insn{opcode: 0xE9, mnemonic: :jp, operands: [{:pair, :hl}], cycles: 4}
      ] ++
        for {condition, index} <- @conditions do
          %Insn{
            opcode: 0xC2 + index * 8,
            mnemonic: :jp,
            operands: [{:imm, 16}],
            condition: condition,
            cycles: 16,
            cycles_untaken: 12
          }
        end

    call =
      [%Insn{opcode: 0xCD, mnemonic: :call, operands: [{:imm, 16}], cycles: 24}] ++
        for {condition, index} <- @conditions do
          %Insn{
            opcode: 0xC4 + index * 8,
            mnemonic: :call,
            operands: [{:imm, 16}],
            condition: condition,
            cycles: 24,
            cycles_untaken: 12
          }
        end

    ret =
      [
        %Insn{opcode: 0xC9, mnemonic: :ret, cycles: 16},
        # RETI : RET + IME. L'autorisation est immédiate, contrairement au délai
        # d'une instruction de EI.
        %Insn{opcode: 0xD9, mnemonic: :reti, cycles: 16}
      ] ++
        for {condition, index} <- @conditions do
          %Insn{
            opcode: 0xC0 + index * 8,
            mnemonic: :ret,
            condition: condition,
            cycles: 20,
            cycles_untaken: 8
          }
        end

    rst =
      for slot <- 0..7 do
        %Insn{opcode: 0xC7 + slot * 8, mnemonic: :rst, operands: [{:rst, slot * 8}], cycles: 16}
      end

    jp ++ call ++ ret ++ rst
  end

  # ── x=1 : LD r, r' ──────────────────────────────────────────────────────────

  defp load_block do
    for dst <- 0..7, src <- 0..7, not (dst == 6 and src == 6) do
      %Insn{
        opcode: 0x40 + dst * 8 + src,
        mnemonic: :ld,
        operands: [operand(dst), operand(src)],
        # Un accès mémoire coûte un M-cycle de plus, quel que soit le côté de
        # l'affectation. Les deux à la fois n'existe pas : `dst = src = 6` aurait
        # été « LD (HL), (HL) », encodage réquisitionné par HALT.
        cycles: if(dst == 6 or src == 6, do: 8, else: 4)
      }
    end
  end

  # ── x=2 : ALU A, r ──────────────────────────────────────────────────────────

  # Les huit opérations, dans l'ordre du champ `y`. Cet ordre n'est pas un choix
  # de ce projet : c'est l'encodage du silicium.
  @alu {:add, :adc, :sub, :sbc, :and, :xor, :or, :cp}

  defp alu_imm_block do
    for y <- 0..7 do
      %Insn{
        opcode: 0xC6 + y * 8,
        mnemonic: elem(@alu, y),
        operands: [{:reg, :a}, {:imm, 8}],
        cycles: 8
      }
    end
  end

  defp alu_block do
    for y <- 0..7, z <- 0..7 do
      %Insn{
        opcode: 0x80 + y * 8 + z,
        mnemonic: elem(@alu, y),
        # A figure explicitement comme premier opérande des huit, y compris de
        # celles que l'assembleur écrit sans le mentionner (`SUB B`, `AND B`).
        # A est bien lu et — sauf pour CP — écrit ; l'omettre rendrait la table
        # irrégulière là où le processeur ne l'est pas.
        operands: [{:reg, :a}, operand(z)],
        cycles: if(z == 6, do: 8, else: 4)
      }
    end
  end
end
