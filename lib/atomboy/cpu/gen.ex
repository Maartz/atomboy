defmodule Atomboy.CPU.Gen do
  @moduledoc """
  Traduit un `Atomboy.CPU.Insn` en clause de fonction, à la compilation.

  C'est la seule couche qui connaît la convention d'appel. `Atomboy.CPU.Table`
  décrit *quoi*, ce module décide *comment* — de sorte qu'un changement de
  convention se fait ici, et nulle part ailleurs.

  ## La convention d'appel

  `exec(opcode, %State{} = st, mem)` renvoie `{state, mem, t_cycles}`.

  Le code émis lit ses opérandes par accès de champ (`st.c`) et n'écrit qu'une
  seule fois, par mise à jour de map (`%{st | b: st.c}`), en groupant tous les
  champs touchés dans la même expression : deux mises à jour successives
  copieraient la structure deux fois.

  Une propriété utile en découle : **une instruction qui ne modifie aucun
  registre ne réalloue rien**. `NOP` et `LD (HL), r` repassent `st` tel quel.
  Avec un tuple positionnel, il fallait le reconstruire à chaque instruction,
  qu'elle change quelque chose ou non.

  ## Ce que cette convention a fait disparaître

  La version précédente passait les dix registres en arguments séparés
  (`exec/13`). Elle imposait une machinerie annexe : comme `LD B, C` écrase `b`
  sans le lire, l'argument `b` était inutilisé, et chaque clause générée
  produisait un avertissement du compilateur. Il fallait donc inspecter l'AST du
  corps pour préfixer d'un souligné les variables non lues — sans quoi des
  centaines d'avertissements parasites noyaient ceux qui comptent.

  Avec un état nommé, il n'y a que deux arguments et ils sont toujours lus. Tout
  ce mécanisme n'a plus lieu d'être.

  ## Ce qui reste à faire ici

  `exec/3` renvoie un tuple, soit une allocation par instruction. L'étape
  suivante est l'appel terminal : au lieu de renvoyer, enchaîner directement sur
  le fetch suivant et ne matérialiser le résultat qu'en fin de budget de cycles
  — une fois par scanline au lieu d'une fois par instruction. Ça se change dans
  `ret/3`, pas dans 500 clauses.
  """

  alias Atomboy.CPU.Insn

  @doc """
  La clause de `exec/3` correspondant à une instruction.

  Renvoie `{arguments, corps}`, à injecter par `unquote_splicing/1` et
  `unquote/1` dans un `def` chez l'appelant.
  """
  @spec clause(Insn.t()) :: {[Macro.t()], Macro.t()}
  def clause(%Insn{} = insn), do: {[var(:st), var(:mem)], body(insn)}

  @doc """
  Une variable non hygiénique.

  Le contexte `nil` est indispensable : ces variables sont construites ici mais
  doivent se lier à celles de la tête de fonction dans `Atomboy.CPU`. Avec le
  contexte par défaut elles appartiendraient à ce module et ne matcheraient rien.
  """
  @spec var(atom()) :: Macro.t()
  def var(name), do: Macro.var(name, nil)

  # ── Corps, par famille ──────────────────────────────────────────────────────

  defp body(%Insn{mnemonic: :nop, cycles: cycles}) do
    ret(var(:st), var(:mem), cycles)
  end

  # LD (HL), r — la mémoire change, l'état non : `st` repart tel quel.
  defp body(%Insn{mnemonic: :ld, operands: [:hl_ind, src], cycles: cycles}) do
    ret(var(:st), mem_write(read(src)), cycles)
  end

  # LD r, r' et LD r, (HL) — un seul champ change.
  defp body(%Insn{mnemonic: :ld, operands: [{:reg, dst}, src], cycles: cycles}) do
    ret(update(%{dst => read(src)}), var(:mem), cycles)
  end

  # ALU A, r — la sémantique est dans `Atomboy.CPU.ALU`, qui renvoie l'état mis
  # à jour. Ce module ne décide que de l'aiguillage : quelle primitive, sur quel
  # opérande.
  defp body(%Insn{mnemonic: mnemonic, operands: [{:reg, :a}, src], cycles: cycles})
       when mnemonic in [:add, :adc, :sub, :sbc, :and, :xor, :or, :cp] do
    call = {{:., [], [Atomboy.CPU.ALU, alu_function(mnemonic)]}, [], [var(:st), read(src)]}
    ret(call, var(:mem), cycles)
  end

  # `and`, `or` et `xor` sont des opérateurs d'Elixir : les primitives portent
  # un autre nom, sans que la table ait à s'écarter du mnémonique du matériel.
  defp alu_function(:and), do: :bit_and
  defp alu_function(:xor), do: :bit_xor
  defp alu_function(:or), do: :bit_or
  defp alu_function(mnemonic), do: mnemonic

  # ── Briques ─────────────────────────────────────────────────────────────────

  # L'expression qui lit un opérande source.
  defp read(:hl_ind) do
    quote do: mem_read(unquote(var(:mem)), unquote(var(:st)))
  end

  defp read({:reg, name}), do: field(name)

  # `st.<name>`
  defp field(name), do: {{:., [], [var(:st), name]}, [no_parens: true], []}

  # `%{st | champ: valeur, ...}` — une seule mise à jour, tous champs groupés.
  defp update(fields) when map_size(fields) > 0 do
    {:%{}, [], [{:|, [], [var(:st), Enum.to_list(fields)]}]}
  end

  # L'expression qui écrit `value` à l'adresse HL et renvoie la nouvelle mémoire.
  defp mem_write(value) do
    quote do
      mem_write(unquote(var(:mem)), unquote(var(:st)), unquote(value))
    end
  end

  # La valeur de retour de `exec/3`.
  defp ret(state_expr, mem_expr, cycles) do
    {:{}, [], [state_expr, mem_expr, cycles]}
  end
end
