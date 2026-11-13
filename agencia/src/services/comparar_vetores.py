"""Comparacao de dois relogios vetoriais (Sprint 3, Parte E).

Mesma regra usada no mesclar_logs.py do Sprint 2, agora chamada em tempo real
pelo endpoint de sincronizacao offline-first:

    IGUAIS        nenhuma posicao difere
    ANTES         v1 <= v2 em todas as posicoes (v1 aconteceu antes de v2)
    DEPOIS        v2 <= v1 em todas as posicoes (v1 aconteceu depois de v2)
    CONCORRENTES  nenhum dos dois e menor-ou-igual ao outro

Funcao pura (sem estado, sem rede): pode ser testada isoladamente.
"""


def comparar_vetores(v1, v2):
    if len(v1) != len(v2):
        raise ValueError(f"vetores de tamanhos diferentes: {len(v1)} e {len(v2)}")

    v1_menor_ou_igual = True
    v2_menor_ou_igual = True
    for a, b in zip(v1, v2):
        if a > b:
            v1_menor_ou_igual = False
        if b > a:
            v2_menor_ou_igual = False

    if v1_menor_ou_igual and v2_menor_ou_igual:
        return "IGUAIS"
    if v1_menor_ou_igual:
        return "ANTES"
    if v2_menor_ou_igual:
        return "DEPOIS"
    return "CONCORRENTES"
