from hello_common.app import run
from hello_common.secrets import resolve_env


def main() -> None:
    resolve_env()  # dsv:// references -> values (Delinea DSV) before any setting is read
    from .main import build_app

    run(build_app())


if __name__ == "__main__":
    main()
