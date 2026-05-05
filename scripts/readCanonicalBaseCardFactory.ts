/**
 * Canonical Base Card Factory address for tooling (config → base-UserCardFactory.json → FullAccount snapshot).
 * Mirrors checkCreateCardDeployerConfig.ts / createCCSA preference order — never prefer stale FullAccount only.
 */
import * as fs from "fs";
import * as path from "path";

const DEFAULT_BASE_CARD_FACTORY = "0x52cc9E977Ca3EA33c69383a41F87f32a71140A52";

/** @param deploymentsDir Absolute or repo-relative `deployments` directory path */
export function resolveBaseCardFactoryAddress(deploymentsDir: string): string {
	if (typeof process.env.CARD_FACTORY_ADDRESS === "string") {
		const e = process.env.CARD_FACTORY_ADDRESS.trim();
		if (e.startsWith("0x") && e.length === 42) return e;
	}
	for (const k of ["CARD_FACTORY", "BEAMIO_CARD_FACTORY"] as const) {
		const raw = process.env[k];
		if (typeof raw === "string") {
			const e = raw.trim();
			if (e.startsWith("0x") && e.length === 42) return e;
		}
	}
	const configPath = path.join(deploymentsDir, "..", "config", "base-addresses.json");
	try {
		if (fs.existsSync(configPath)) {
			const cfg = JSON.parse(fs.readFileSync(configPath, "utf-8")) as { CARD_FACTORY?: string };
			if (typeof cfg.CARD_FACTORY === "string" && cfg.CARD_FACTORY.startsWith("0x")) return cfg.CARD_FACTORY.trim();
		}
	} catch {
		/* skip */
	}
	const factoryJson = path.join(deploymentsDir, "base-UserCardFactory.json");
	try {
		if (fs.existsSync(factoryJson)) {
			const fd = JSON.parse(fs.readFileSync(factoryJson, "utf-8")) as {
				contracts?: { beamioUserCardFactoryPaymaster?: { address?: string } };
			};
			const a = fd.contracts?.beamioUserCardFactoryPaymaster?.address;
			if (typeof a === "string" && a.startsWith("0x")) return a.trim();
		}
	} catch {
		/* skip */
	}
	const fullPath = path.join(deploymentsDir, "base-FullAccountAndUserCard.json");
	try {
		if (fs.existsSync(fullPath)) {
			const data = JSON.parse(fs.readFileSync(fullPath, "utf-8")) as {
				contracts?: { beamioUserCardFactoryPaymaster?: { address?: string } };
			};
			const a = data.contracts?.beamioUserCardFactoryPaymaster?.address;
			if (typeof a === "string" && a.startsWith("0x")) return a.trim();
		}
	} catch {
		/* skip */
	}
	return DEFAULT_BASE_CARD_FACTORY;
}
